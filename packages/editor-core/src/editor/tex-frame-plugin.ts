import {
  Decoration,
  DecorationSet,
  EditorView,
  WidgetType,
} from '@codemirror/view';
import { EditorState, Extension, StateField, Text } from '@codemirror/state';
import { readGroup, uncommented, VERBATIM_CLOSE, VERBATIM_OPEN } from './tex-lines';
import { collapsedLineRange, collapsedLineRevealed, makeFenceStopKeymap } from './callout-core';
import { isPreviewMode } from './view-mode';
import { HIDE, lineRevealed, SYNTAX_DIM } from './reveal';
import { createRevealGate, revealSignal } from './reveal-gate';
import '../styles/slide.css';
import { memoByDoc } from '../utils/memo-by-doc';

// Beamer frames as slide cards: a hairline box with a tinted title band and the
// slide number. Both title syntaxes, `\begin{frame}{T}{S}` and
// `\frametitle`/`\framesubtitle`, must produce the same band.
// `\pause`, overlay specs (`<2->`) and `columns` stay raw source on purpose:
// side-by-side would need a block widget with editable islands (like tables).
// A line scanner with line decorations only, so interior content keeps
// rendering.

/** One closed `\begin{frame}…\end{frame}` region. */
interface FrameRegion {
  /** 1-based lines. */
  openLine: number;
  closeLine: number;
  number: number;
  title: string | null;
  subtitle: string | null;
  /** Line of the `\frametitle{…}` that supplied the title; undefined for the
   *  brace form. Decides which row carries the band. */
  titleLine?: number;
  subtitleLine?: number;
  /** Common leading whitespace of the body, hidden. Only the COMMON prefix, so
   *  nested lists keep their relative depth. */
  indent: number;
  /** Verbatim bodies (1-based, inclusive), never dedented. */
  verbatim: Array<{ from: number; to: number }>;
}

// Must START the line, so a macro definition like
// `\newcommand{\qf}[1]{\begin{frame}{#1}\end{frame}}` is not a frame.
const FRAME_OPEN = /^\s*\\begin\{frame\}/;
const FRAME_CLOSE = /^\s*\\end\{frame\}\s*$/;
const FRAME_TITLE = /^\s*\\frametitle\s*\{/;
const FRAME_SUBTITLE = /^\s*\\framesubtitle\s*\{/;

const DOCUMENTCLASS = /\\documentclass\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}/;

/** Skip `[…]` option groups and surrounding inline whitespace. */
function skipOptions(s: string, at: number): number {
  let i = at;
  for (;;) {
    while (s[i] === ' ' || s[i] === '\t') i++;
    if (s[i] !== '[') return i;
    const close = s.indexOf(']', i);
    if (close === -1) return i;
    i = close + 1;
  }
}

/** Title/subtitle from a lone `\begin{frame}` line's brace arguments; null when
 *  the line is not a lone frame open. */
function parseFrameOpen(lineText: string): { title: string | null; subtitle: string | null } | null {
  const text = uncommented(lineText);
  if (!FRAME_OPEN.test(text)) return null;

  let i = text.indexOf('\\begin{frame}') + '\\begin{frame}'.length;
  i = skipOptions(text, i);

  let title: string | null = null;
  let subtitle: string | null = null;
  if (text[i] === '{') {
    const g = readGroup(text, i);
    if (!g) return null;
    title = g.value;
    i = g.end;
    while (text[i] === ' ' || text[i] === '\t') i++;
    if (text[i] === '{') {
      const g2 = readGroup(text, i);
      if (!g2) return null;
      subtitle = g2.value;
      i = g2.end;
    }
  }

  const rest = text.slice(i).trim();
  const tail = rest.replace(/^\\label\s*\{[^}]*\}/, '').trim();
  if (tail !== '') return null;

  return { title, subtitle };
}

function commandArg(lineText: string, re: RegExp): string | null {
  const text = uncommented(lineText);
  const m = re.exec(text);
  if (!m) return null;
  const g = readGroup(text, m[0].length - 1);
  return g ? g.value : null;
}

// ── The beamer gate ──

/** Gates all slide chrome, since `frame` is a plausible env name elsewhere: a
 *  non-beamer `\documentclass` is out; a class-less fragment (an `\input`
 *  slide file) is in if it has a frame. */
export const isBeamerDoc = memoByDoc(computeIsBeamer);

// Test-only: lines the `\documentclass` regex ran on, pinning the substring
// reject in computeIsBeamer.
let documentclassProbes = 0;
export function __documentclassProbeCount(): number {
  return documentclassProbes;
}
export function __resetDocumentclassProbeCount(): void {
  documentclassProbes = 0;
}

// Line-wise with early exit, NOT `doc.toString()` + regex: it runs per
// document change for every `.tex` file (typing-perf.test.ts).
function computeIsBeamer(doc: Text): boolean {
  for (const text of doc.iterLines()) {
    // Substring reject before the regex (a plain `indexOf` per prose line).
    // The frame test stays SECOND: a line with both is decided by its class.
    if (text.includes('\\documentclass')) {
      documentclassProbes++;
      const cls = DOCUMENTCLASS.exec(text);
      if (cls) return cls[1].trim() === 'beamer';
    }
    if (text.includes('\\begin{frame}')) return true;
  }
  return false;
}

// ── Scan ──

// Test-only: cache-miss scan count, so a test can pin the caching invariant.
let scanMisses = 0;
export function __frameScanCount(): number {
  return scanMisses;
}
export function __resetFrameScanCount(): void {
  scanMisses = 0;
}

/**
 * CLOSED frame regions in document order (a half-typed frame decorates
 * nothing). Non-nested, verbatim-guarded, gated on `isBeamerDoc`. Cached per
 * document: treat the array as immutable.
 */
export const scanTexFrames = memoByDoc(computeFrames);

function verbatimClosesBelow(doc: Text, fromLine: number, env: string): boolean {
  if (fromLine > doc.lines) return false;
  for (const text of doc.iterLines(fromLine)) {
    const m = VERBATIM_CLOSE.exec(text);
    if (m && m[1] === env) return true;
  }
  return false;
}

function computeFrames(doc: Text): FrameRegion[] {
  scanMisses++;
  if (!isBeamerDoc(doc)) return [];

  const regions: FrameRegion[] = [];
  let open: { title: string | null; subtitle: string | null } | null = null;
  let openLine = 0;
  let titleLine: number | undefined;
  let subtitleLine: number | undefined;
  let verbatimEnv: string | null = null;
  let verbatimStart = 0;
  let verbatim: Array<{ from: number; to: number }> = [];
  let indent = Infinity;

  let n = 0;
  for (const text of doc.iterLines()) {
    n++;

    // Verbatim bodies are opaque: only the matching \end exits.
    if (verbatimEnv) {
      const end = VERBATIM_CLOSE.exec(text);
      if (end && end[1] === verbatimEnv) {
        verbatimEnv = null;
        if (open) verbatim.push({ from: verbatimStart, to: n });
        continue;
      }
      // An UNTERMINATED verbatim ends at the frame's close (LaTeX's rule), so
      // fall through; otherwise every card below would vanish. A verbatim that
      // closes later swallows a quoted `\end{frame}` as text.
      if (
        !open ||
        !FRAME_CLOSE.test(uncommented(text)) ||
        verbatimClosesBelow(doc, n + 1, verbatimEnv)
      )
        continue;
    }
    const verb = VERBATIM_OPEN.exec(text);
    if (verb) {
      verbatimEnv = verb[1];
      verbatimStart = n;
      continue;
    }

    if (open) {
      if (FRAME_CLOSE.test(uncommented(text))) {
        if (verbatimEnv) {
          verbatim.push({ from: verbatimStart, to: n });
          verbatimEnv = null;
        }
        regions.push({
          openLine,
          closeLine: n,
          number: regions.length + 1,
          title: open.title,
          subtitle: open.subtitle,
          titleLine,
          subtitleLine,
          indent: Number.isFinite(indent) ? indent : 0,
          verbatim,
        });
        open = null;
        continue;
      }
      // Command-form title/subtitle only when the brace form gave none.
      if (open.title === null && titleLine === undefined) {
        const t = commandArg(text, FRAME_TITLE);
        if (t !== null) {
          open.title = t;
          titleLine = n;
          continue;
        }
      }
      if (open.subtitle === null && subtitleLine === undefined) {
        const s = commandArg(text, FRAME_SUBTITLE);
        if (s !== null) {
          open.subtitle = s;
          subtitleLine = n;
          continue;
        }
      }
      // Blank lines would pin the common prefix to zero.
      if (text.trim() !== '') {
        indent = Math.min(indent, text.length - text.trimStart().length);
      }
      continue;
    }

    const parsed = parseFrameOpen(text);
    if (parsed) {
      open = parsed;
      openLine = n;
      titleLine = undefined;
      subtitleLine = undefined;
      indent = Infinity;
      verbatim = [];
    }
  }

  return regions;
}

// ── Decorations ── (same stacked line-class idiom as callouts; geometry in slide.css)

/** Replaces a `\begin{frame}{Title}{Subtitle}` line. */
class FrameHeaderWidget extends WidgetType {
  constructor(
    private readonly title: string,
    private readonly subtitle: string | null,
  ) {
    super();
  }

  eq(other: FrameHeaderWidget): boolean {
    return other.title === this.title && other.subtitle === this.subtitle;
  }

  toDOM(): HTMLElement {
    const span = document.createElement('span');
    span.className = 'cm-slide-header';
    const title = document.createElement('span');
    title.className = 'cm-slide-title';
    title.textContent = this.title;
    span.appendChild(title);
    if (this.subtitle) {
      // A <br>, not `display: block`, which adds an empty line of band height
      // (see slide.css).
      span.appendChild(document.createElement('br'));
      const sub = document.createElement('span');
      sub.className = 'cm-slide-subtitle';
      sub.textContent = this.subtitle;
      span.appendChild(sub);
    }
    return span;
  }

  ignoreEvent(): boolean {
    return false; // let clicks through so the caret can enter the fence line
  }
}

/**
 * `calloutBlockAt`'s twin: whether a block widget (display math) sits inside a
 * frame body, so it carries the card's side edges. Skip it and every `\[…\]`
 * breaks the box open. No `bottom`/`hideTo`: the `\end{frame}` row is always
 * the foot.
 */
export function frameBlockAt(doc: Text, from: number, to: number): boolean {
  const regions = scanTexFrames(doc);
  if (regions.length === 0) return false;
  const startLine = doc.lineAt(from).number;
  const endLine = doc.lineAt(Math.max(from, to - 1)).number;
  return regions.some((r) => startLine > r.openLine && endLine < r.closeLine);
}

/**
 * True when neither selection touches a frame's lines (or the line above, whose
 * break a collapsed open fence hides): no reveal can then change the set.
 */
function frameSelectionIndependent(a: EditorState, b: EditorState): boolean {
  const regions = scanTexFrames(b.doc);
  if (regions.length === 0) return true;
  const lines = [a.selection.main, b.selection.main].flatMap((m) => [
    b.doc.lineAt(m.anchor).number,
    b.doc.lineAt(m.head).number,
  ]);
  return !regions.some((r) => lines.some((n) => n >= r.openLine - 1 && n <= r.closeLine));
}

interface TexFrameOptions {
  /** `false` (Mixed): nothing collapses or hides. The raw fence row tops the
   *  band, brace-form titles get the command form's mark classes, the rest of
   *  the fence rows is dimmed. */
  conceal?: boolean;
}

const TITLE_MARK = Decoration.mark({ class: 'cm-tex-frametitle' });
const SUBTITLE_MARK = Decoration.mark({ class: 'cm-tex-framesubtitle' });

function buildFrameDecorations(
  state: EditorState,
  opts: TexFrameOptions = {},
): DecorationSet {
  const conceal = opts.conceal ?? true;
  const { doc } = state;
  const cursor = state.selection.main;
  const regions = scanTexFrames(doc);
  if (regions.length === 0) return Decoration.none;

  const decos: Array<{ from: number; to: number; deco: Decoration }> = [];

  for (const region of regions) {
    const openLine = doc.line(region.openLine);
    const closeLine = doc.line(region.closeLine);

    // `\frametitle` form: the bare fence collapses and the band moves onto the
    // \frametitle row. Brace form: the fence row becomes the header widget.
    const usesCommandTitle = region.titleLine != null;
    const hideOpen =
      conceal && usesCommandTitle && !collapsedLineRevealed(doc, cursor, region.openLine);
    const headerLine = hideOpen ? region.titleLine! : region.openLine;

    // The band also takes an adjacent `\framesubtitle` row, so both syntaxes
    // share one band. Its hairline goes on the last row.
    let bandEnd = headerLine;
    if (conceal) {
      const subtitleInBand =
        usesCommandTitle &&
        region.subtitleLine != null &&
        region.subtitleLine === headerLine + 1;
      if (subtitleInBand) bandEnd = region.subtitleLine!;
    } else {
      let n = region.openLine + 1;
      while (n === region.titleLine || n === region.subtitleLine) {
        bandEnd = n;
        n++;
      }
    }

    // The `\end{frame}` row is the card's FOOT: text hidden, row kept, always
    // `cm-slide-bottom`. Don't collapse it and close on the last body row: a
    // frame ending in a block has `\end{block}` collapsed by the callout plugin
    // too, so no candidate row survives and the card never closes; and a
    // nested callout row is inset, so a foot there is narrower than the sides.
    const hideClose =
      conceal && !lineRevealed(cursor, closeLine.from, closeLine.to);
    const bottomLine = region.closeLine;

    for (let n = region.openLine; n <= region.closeLine; n++) {
      if (n === region.openLine && hideOpen) continue;
      const line = doc.line(n);
      let cls = 'cm-slide';
      if (n === headerLine) cls += ' cm-slide-top';
      // Every row in between too: Mixed can put three rows in the band.
      if (n >= headerLine && n <= bandEnd) cls += ' cm-slide-band';
      if (n === bandEnd) cls += ' cm-slide-band-end';
      if (n === bottomLine) cls += ' cm-slide-bottom';
      decos.push({
        from: line.from,
        to: line.from,
        deco: Decoration.line(
          n === headerLine
            ? { class: cls, attributes: { 'data-slide': String(region.number) } }
            : { class: cls },
        ),
      });
    }

    if (hideOpen) {
      const openHide = collapsedLineRange(doc, region.openLine);
      decos.push({ from: openHide.from, to: openHide.to, deco: HIDE });
    } else if (
      conceal &&
      !usesCommandTitle &&
      !lineRevealed(cursor, openLine.from, openLine.to) &&
      openLine.from < openLine.to
    ) {
      decos.push({
        from: openLine.from,
        to: openLine.to,
        deco: Decoration.replace({
          widget: new FrameHeaderWidget(region.title ?? '', region.subtitle),
        }),
      });
    }

    // Hide the common body indent (not in verbatim, where it is content);
    // revealed per line by the caret.
    if (conceal && region.indent > 0) {
      for (let n = region.openLine + 1; n < region.closeLine; n++) {
        if (n === region.titleLine || n === region.subtitleLine) continue;
        if (region.verbatim.some((v) => n >= v.from && n <= v.to)) continue;
        const line = doc.line(n);
        if (line.text.trim() === '') continue;
        const hide = Math.min(
          region.indent,
          line.text.length - line.text.trimStart().length,
        );
        if (hide <= 0) continue;
        if (lineRevealed(cursor, line.from, line.to, line.from, line.from + hide)) continue;
        decos.push({
          from: line.from,
          to: line.from + hide,
          deco: HIDE,
        });
      }
    }

    // Hide the command form's band-row indent so its title sits where the brace
    // form's widget puts it (both syntaxes must match). Revealed by the caret.
    if (conceal && usesCommandTitle) {
      const subtitleInBand =
        region.subtitleLine != null && region.subtitleLine === bandEnd;
      for (const n of [region.titleLine, subtitleInBand ? region.subtitleLine : undefined]) {
        if (n == null) continue;
        const line = doc.line(n);
        const indent = line.text.length - line.text.trimStart().length;
        if (indent === 0) continue;
        if (lineRevealed(cursor, line.from, line.to, line.from, line.from + indent)) continue;
        decos.push({
          from: line.from,
          to: line.from + indent,
          deco: HIDE,
        });
      }
    }

    // Text only, never the preceding newline: the row has to survive as the
    // card's foot.
    if (hideClose && closeLine.from < closeLine.to) {
      decos.push({
        from: closeLine.from,
        to: closeLine.to,
        deco: HIDE,
      });
    }

    if (!conceal) {
      // Dim the pieces AROUND the title arguments, not the whole row:
      // overlapping marks merge classes and the dim's opacity would hit the
      // title too.
      const t = openLine.text;
      const pieces: Array<{ from: number; to: number; deco: Decoration }> = [];
      let cursorIdx = 0;
      const dimTo = (idx: number): void => {
        if (idx > cursorIdx) pieces.push({ from: openLine.from + cursorIdx, to: openLine.from + idx, deco: SYNTAX_DIM });
      };
      const frameIdx = t.indexOf('{frame}');
      if (!usesCommandTitle && region.title && frameIdx >= 0) {
        const ti = t.indexOf(region.title, frameIdx + '{frame}'.length);
        if (ti >= 0) {
          dimTo(ti);
          pieces.push({ from: openLine.from + ti, to: openLine.from + ti + region.title.length, deco: TITLE_MARK });
          cursorIdx = ti + region.title.length;
          if (region.subtitle) {
            const si = t.indexOf(region.subtitle, cursorIdx);
            if (si >= 0) {
              dimTo(si);
              pieces.push({ from: openLine.from + si, to: openLine.from + si + region.subtitle.length, deco: SUBTITLE_MARK });
              cursorIdx = si + region.subtitle.length;
            }
          }
        }
      }
      // No title match: the rest of the line is dimmed.
      dimTo(t.length);
      decos.push(...pieces);
      if (closeLine.from < closeLine.to) {
        decos.push({ from: closeLine.from, to: closeLine.to, deco: SYNTAX_DIM });
      }
    }
  }

  return Decoration.set(
    decos.map((d) => d.deco.range(d.from, d.to)),
    true,
  );
}

/** A StateField, not a ViewPlugin: fence hides replace line breaks, which CM6
 *  forbids from plugins. */
export function texFramePlugin(opts: TexFrameOptions = {}): Extension {
  // Pointer freeze as for every reveal (reveal-gate.ts). Mixed reveals nothing,
  // so it is always selection-independent.
  const gate = createRevealGate({
    selectionIndependent: (opts.conceal ?? true) ? frameSelectionIndependent : () => true,
  });
  const field = StateField.define<DecorationSet>({
    create(state) {
      return buildFrameDecorations(state, opts);
    },
    update(decos, tr) {
      if (gate.decide(revealSignal(tr)) !== 'rebuild') return decos.map(tr.changes);
      return buildFrameDecorations(tr.state, opts);
    },
    provide: (f) => EditorView.decorations.from(f),
  });
  return [field];
}

/** Up/Down stop on the one row a frame collapses, the bare open fence of a
 *  \frametitle-form frame. `\end{frame}` is a real row and needs no stop. */
export const texFrameFenceKeymap: Extension = makeFenceStopKeymap(
  memoByDoc((doc: Text) =>
    scanTexFrames(doc)
      .filter((r) => r.titleLine != null)
      .map((r) => ({ closeLine: r.openLine })),
  ),
  isPreviewMode,
);
