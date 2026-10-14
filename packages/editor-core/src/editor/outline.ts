import type { EditorState, Text } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import type { Language } from './setup';
import { scanCallouts } from './md-callout-plugin';
import { scanTexCallouts } from './tex-callout-plugin';
import { scanTexImages } from './tex-image';
import { commentStart, inLineComment } from './tex-lines';
import { scanTexFrames } from './tex-frame-plugin';
import { docText } from '../utils/doc-text';
import { memoByDoc } from '../utils/memo-by-doc';

/** One entry in the document outline (Table of Contents). */
export interface OutlineItem {
  kind: 'heading' | 'callout' | 'figure' | 'frame';
  /** Heading depth 1 to 6; 0 for callouts, figures and frames (indented under
   *  the preceding heading). */
  level: number;
  /** Display text without `#`s or the `\section{}` wrapper; `''` for an
   *  untitled callout. */
  title: string;
  /** 1-based line, for `gotoLine`. */
  line: number;
  /** Callouts only: `theorem`, `definition`, etc. */
  calloutType?: string;
  /** Callout per-type ordinal, figure ordinal, or slide number. */
  number?: number;
}

const TEX_LEVELS: Record<string, number> = {
  part: 1,
  chapter: 2,
  section: 3,
  subsection: 4,
  subsubsection: 5,
  paragraph: 6,
  subparagraph: 6,
};

// Tolerates an optional `[short title]`; spaces/tabs only so the match never
// crosses a newline.
const TEX_SECTION =
  /\\(subsubsection|subsection|subparagraph|paragraph|section|chapter|part)\*?[ \t]*(?:\[[^\]\n]*\])?[ \t]*\{/g;

// A section command after one of these on its line is a macro body
// (`\newcommand{\mysec}[1]{\section*{#1}}`), not structure.
const MACRO_DEF =
  /\\(?:(?:re)?newcommand|providecommand|(?:re)?newenvironment|DeclareRobustCommand|NewDocumentCommand|RenewDocumentCommand|ProvideDocumentCommand|def)\b/;

// Literal-text environments: a `\section` inside is quoted, not structure.
const VERBATIM_LIKE = /\\begin\{(verbatim\*?|Verbatim\*?|lstlisting\*?|minted|comment)\}/g;

/** Ranges covered by verbatim-family and comment environments; an unclosed
 *  one runs to the end of input, as in LaTeX. */
function scanVerbatimRanges(doc: string): { from: number; to: number }[] {
  const ranges: { from: number; to: number }[] = [];
  VERBATIM_LIKE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = VERBATIM_LIKE.exec(doc)) !== null; ) {
    const endMarker = `\\end{${m[1]}}`;
    const endIdx = doc.indexOf(endMarker, m.index + m[0].length);
    const to = endIdx === -1 ? doc.length : endIdx + endMarker.length;
    ranges.push({ from: m.index, to });
    VERBATIM_LIKE.lastIndex = to;
  }
  return ranges;
}

/** Inner text of the brace-balanced argument opening at `openBrace`, bounded
 *  to one line. */
function readBracedArg(s: string, openBrace: number): string {
  let depth = 0;
  let out = '';
  for (let i = openBrace; i < s.length; i++) {
    const ch = s[i];
    if (ch === '\n') break;
    if (ch === '{') {
      depth++;
      if (depth === 1) continue; // skip the outermost opener
    } else if (ch === '}') {
      depth--;
      if (depth === 0) break;
    }
    out += ch;
  }
  return out.trim();
}

/** `path/to/plot.pdf` to `plot`. */
function basename(path: string): string {
  const file = path.slice(path.lastIndexOf('/') + 1);
  const dot = file.lastIndexOf('.');
  return dot > 0 ? file.slice(0, dot) : file;
}

interface TexFigure {
  /** 1-based line of the `\begin{figure}`. */
  line: number;
  /** First caption, else first image basename, else "Figure". */
  title: string;
}

const FIGURE_OPEN = /^\s*\\begin\{figure\*?\}/;
// Not line-anchored: the close can share a line with the open or a caption.
const FIGURE_CLOSE = /\\end\{figure\*?\}/;
const CAPTION = /\\caption\s*\{/;

/** Closed figure environments, ignoring `%` comments. Memoized per doc. */
export const scanTexFigures = memoByDoc((doc: Text): TexFigure[] => {
  const figures: TexFigure[] = [];
  let openLine = 0; // 0 = not inside a figure environment
  let caption: string | null = null;
  let imagePath: string | null = null;

  for (let n = 1; n <= doc.lines; n++) {
    let text = doc.line(n).text;
    const cs = commentStart(text);
    if (cs !== -1) text = text.slice(0, cs);

    if (openLine === 0) {
      const open = FIGURE_OPEN.exec(text);
      if (!open) continue;
      openLine = n;
      caption = null;
      imagePath = null;
      // The rest of the open line can hold content and even the close.
      text = text.slice(open[0].length);
    }
    // Content before the close (if any) still counts for caption/image.
    const close = FIGURE_CLOSE.exec(text);
    const body = close ? text.slice(0, close.index) : text;
    if (caption === null) {
      const m = CAPTION.exec(body);
      if (m) caption = readBracedArg(body, m.index + m[0].length - 1);
    }
    if (imagePath === null) {
      const im = scanTexImages(body)[0];
      if (im) imagePath = im.path;
    }
    if (close) {
      figures.push({
        line: openLine,
        title: caption || (imagePath ? basename(imagePath) : 'Figure'),
      });
      openLine = 0;
    }
  }

  return figures;
});

function calloutItems(regions: ReturnType<typeof scanCallouts>): OutlineItem[] {
  return regions
    .filter((r) => r.numbered)
    .map((r) => ({
      kind: 'callout' as const,
      level: 0,
      title: r.title ?? '',
      line: r.openLine,
      calloutType: r.type,
      number: r.number,
    }));
}

// Keyed on doc, language and (markdown) syntax tree: with the outline panel
// open every caret move asks again.
const outlineCache = new WeakMap<
  Text,
  { language: Language; tree: ReturnType<typeof syntaxTree> | null; items: OutlineItem[] }
>();

/**
 * Headings, numbered callouts, frames and figures in document order. Callouts
 * come from the same scanners as the rendered boxes, so they always agree. The
 * array is cached and shared: treat it as immutable.
 */
export function extractOutline(state: EditorState, language: Language): OutlineItem[] {
  const tree = language === 'md' ? syntaxTree(state) : null;
  const hit = outlineCache.get(state.doc);
  if (hit && hit.language === language && hit.tree === tree) return hit.items;
  const items = computeOutline(state, language);
  outlineCache.set(state.doc, { language, tree, items });
  return items;
}

function computeOutline(state: EditorState, language: Language): OutlineItem[] {
  const items: OutlineItem[] = [];
  let figureCount = 0;

  if (language === 'md') {
    const callouts = scanCallouts(state.doc);
    // A `::: {#fig-…}` div is listed as its callout, not again as an image.
    const figureDivs = callouts.filter((r) => r.type === 'figure');
    syntaxTree(state).iterate({
      enter(node) {
        const atx = /^ATXHeading(\d)$/.exec(node.name);
        if (atx) {
          const lineObj = state.doc.lineAt(node.from);
          const title = lineObj.text
            .replace(/^\s*#{1,6}\s*/, '') // leading "### " (1-3 space indent is valid)
            .replace(/\s+#+\s*$/, '') // optional closing "###"
            .replace(/\s*\{[^}]*\}\s*$/, '') // trailing Quarto attrs "{#sec-x}"
            .trim();
          items.push({ kind: 'heading', level: Number(atx[1]), title, line: lineObj.number });
          return;
        }
        const setext = /^SetextHeading([12])$/.exec(node.name);
        if (setext) {
          // The title is the first line; the second is the underline.
          const lineObj = state.doc.lineAt(node.from);
          items.push({
            kind: 'heading',
            level: Number(setext[1]),
            title: lineObj.text.replace(/\s*\{[^}]*\}\s*$/, '').trim(),
            line: lineObj.number,
          });
          return;
        }
        if (node.name === 'Image') {
          // Standalone images only; inline images stay out.
          const lineObj = state.doc.lineAt(node.from);
          const indent = lineObj.text.length - lineObj.text.trimStart().length;
          if (node.from !== lineObj.from + indent) return;
          const n = lineObj.number;
          if (figureDivs.some((r) => n > r.openLine && n < r.closeLine)) return;
          const src = state.doc.sliceString(node.from, node.to);
          const alt = /^!\[([^\]]*)\]/.exec(src)?.[1].trim();
          const url = /\]\(\s*<?([^)\s>]+)/.exec(src)?.[1];
          items.push({
            kind: 'figure',
            level: 0,
            title: alt || (url ? basename(url) : 'Figure'),
            line: n,
            number: ++figureCount,
          });
        }
      },
    });
    items.push(...calloutItems(callouts));
    return items.sort((a, b) => a.line - b.line);
  }

  // tex
  const doc = docText(state.doc);
  const verbatim = scanVerbatimRanges(doc);
  for (let m: RegExpExecArray | null; (m = TEX_SECTION.exec(doc)) !== null; ) {
    const lineObj = state.doc.lineAt(m.index);
    // Skip commands sitting in a % line comment.
    if (inLineComment(lineObj, m.index)) continue;
    // Skip quoted commands (verbatim-like environment, macro body).
    const idx = m.index;
    if (verbatim.some((r) => idx >= r.from && idx < r.to)) continue;
    if (MACRO_DEF.test(lineObj.text.slice(0, m.index - lineObj.from))) continue;
    const braceIdx = m.index + m[0].length - 1; // index of the '{'
    items.push({
      kind: 'heading',
      level: TEX_LEVELS[m[1]],
      title: readBracedArg(doc, braceIdx),
      line: lineObj.number,
    });
  }
  // Floats are callout boxes too, but the outline lists figures itself
  // (scanTexFigures, with their captions) and leaves tables out.
  items.push(
    ...calloutItems(
      scanTexCallouts(state.doc).filter((r) => r.type !== 'figure' && r.type !== 'table'),
    ),
  );
  // Beamer slides; scanTexFrames is empty unless isBeamerDoc.
  items.push(
    ...scanTexFrames(state.doc).map((f) => ({
      kind: 'frame' as const,
      level: 0,
      title: f.title ?? '',
      line: f.openLine,
      number: f.number,
    })),
  );
  items.push(
    ...scanTexFigures(state.doc).map((f) => ({
      kind: 'figure' as const,
      level: 0,
      title: f.title,
      line: f.line,
      number: ++figureCount,
    })),
  );
  return items.sort((a, b) => a.line - b.line);
}
