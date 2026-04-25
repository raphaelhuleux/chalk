import {
  Decoration,
  DecorationSet,
  EditorView,
  WidgetType,
} from '@codemirror/view';
import {
  EditorState,
  Extension,
  RangeSetBuilder,
  StateField,
} from '@codemirror/state';
import { KaTeXCache } from '../utils/katex-cache';

export interface MathRegion {
  /** Document offset of the opening delimiter. */
  from: number;
  /** Document offset one past the closing delimiter. */
  to: number;
  /** True = `$$…$$`, `\[…\]`, or `\begin{…}…\end{…}`; false = `$…$`, `\(…\)`. */
  display: boolean;
  /** The LaTeX source to feed KaTeX. For environments, includes the
   *  `\begin…\end` wrapper so KaTeX sees the full construct. */
  content: string;
}

const MATH_ENVIRONMENTS = new Set([
  'equation',
  'equation*',
  'align',
  'align*',
  'gather',
  'gather*',
  'multline',
  'multline*',
  'alignat',
  'alignat*',
  'eqnarray',
  'eqnarray*',
]);

/**
 * Scans a LaTeX source string for math regions. Pure function — takes a
 * string, returns non-overlapping regions in document order. `offset`
 * is added to all returned offsets so callers can scan a sub-range and
 * still get absolute document positions back.
 *
 * Delimiters recognised:
 *   $…$              inline
 *   $$…$$            display
 *   \(…\)            inline
 *   \[…\]            display
 *   \begin{env}…\end{env} where env is in MATH_ENVIRONMENTS
 *
 * Non-math constructs the scanner skips safely:
 *   % line comments (\% is literal)
 *   \$ literal dollar
 *   any other \x escape
 *
 * Not handled (accepted as a Phase-1 limitation):
 *   - verbatim / lstlisting environments (math-like $ inside them would
 *     be picked up as math; acceptable since KaTeX would just fail-parse
 *     and we'd fall back to raw text)
 *   - nested environments (rare in math contexts)
 */
export function scanMathRegions(text: string, offset = 0): MathRegion[] {
  const regions: MathRegion[] = [];
  const n = text.length;
  let i = 0;

  while (i < n) {
    const ch = text[i];

    // Line comment: skip to newline. A preceding backslash escapes the
    // percent sign, but that case is caught in the '\\' branch below —
    // here `%` always starts a comment.
    if (ch === '%') {
      while (i < n && text[i] !== '\n') i++;
      continue;
    }

    if (ch === '\\') {
      // \[ … \] — display math
      if (text[i + 1] === '[') {
        const end = text.indexOf('\\]', i + 2);
        if (end !== -1) {
          regions.push({
            from: offset + i,
            to: offset + end + 2,
            display: true,
            content: text.slice(i + 2, end),
          });
          i = end + 2;
          continue;
        }
      }
      // \( … \) — inline math
      if (text[i + 1] === '(') {
        const end = text.indexOf('\\)', i + 2);
        if (end !== -1) {
          regions.push({
            from: offset + i,
            to: offset + end + 2,
            display: false,
            content: text.slice(i + 2, end),
          });
          i = end + 2;
          continue;
        }
      }
      // \begin{env} … \end{env}
      const beginMatch = matchBegin(text, i);
      if (beginMatch && MATH_ENVIRONMENTS.has(beginMatch.env)) {
        const endMarker = `\\end{${beginMatch.env}}`;
        const endIdx = text.indexOf(endMarker, i + beginMatch.length);
        if (endIdx !== -1) {
          const regionEnd = endIdx + endMarker.length;
          regions.push({
            from: offset + i,
            to: offset + regionEnd,
            display: true,
            // Pass \begin…\end wrapper through to KaTeX; it understands them.
            content: text.slice(i, regionEnd),
          });
          i = regionEnd;
          continue;
        }
      }
      // Any other backslash escape: skip the backslash + next char so we
      // don't mistake \$ for a math delimiter.
      i += 2;
      continue;
    }

    // Display math: $$ … $$
    if (ch === '$' && text[i + 1] === '$') {
      const end = text.indexOf('$$', i + 2);
      if (end !== -1) {
        regions.push({
          from: offset + i,
          to: offset + end + 2,
          display: true,
          content: text.slice(i + 2, end),
        });
        i = end + 2;
        continue;
      }
    }

    // Inline math: $ … $
    if (ch === '$') {
      const end = findInlineDollarClose(text, i + 1);
      if (end !== -1) {
        regions.push({
          from: offset + i,
          to: offset + end + 1,
          display: false,
          content: text.slice(i + 1, end),
        });
        i = end + 1;
        continue;
      }
    }

    i++;
  }

  return regions;
}

/** `\begin{envName}` or `\begin{envName*}` at position `i`. Returns the
 *  environment name and the full `\begin{…}` length, or null. */
function matchBegin(
  text: string,
  i: number,
): { env: string; length: number } | null {
  // Must start with "\begin{"
  if (text.slice(i, i + 7) !== '\\begin{') return null;
  const closeBrace = text.indexOf('}', i + 7);
  if (closeBrace === -1) return null;
  const env = text.slice(i + 7, closeBrace);
  // Accept only identifier chars plus optional trailing star.
  if (!/^[A-Za-z]+\*?$/.test(env)) return null;
  return { env, length: closeBrace - i + 1 };
}

/** Find the next un-escaped `$` starting from `start`. Returns its index
 *  or -1. Skips `\$` as literal. A `$` immediately after a newline (i.e.
 *  an empty inline region) is allowed but produces an empty-content match;
 *  callers can filter if desired. */
function findInlineDollarClose(text: string, start: number): number {
  let j = start;
  while (j < text.length) {
    const c = text[j];
    if (c === '\\') {
      j += 2;
      continue;
    }
    if (c === '$') return j;
    j++;
  }
  return -1;
}

// -----------------------------------------------------------------------
// CM6 widget + view-plugin
// -----------------------------------------------------------------------

class MathWidget extends WidgetType {
  constructor(
    private readonly content: string,
    private readonly display: boolean,
    private readonly cache: KaTeXCache,
  ) {
    super();
  }

  eq(other: MathWidget): boolean {
    return this.content === other.content && this.display === other.display;
  }

  toDOM(): HTMLElement {
    const host = document.createElement(this.display ? 'div' : 'span');
    host.className = this.display ? 'cm-tex-math-display' : 'cm-tex-math-inline';
    const html = this.cache.render(this.content, this.display);
    if (html === null) {
      // Parse error — fall back to a visible raw render the user can fix.
      host.textContent = this.content;
      host.classList.add('cm-tex-math-error');
    } else {
      host.innerHTML = html;
    }
    return host;
  }

  ignoreEvent(): boolean {
    // Let mousedown etc. reach CM6 so clicking the widget positions the
    // cursor (and the cursor-inside-math check then reveals raw source).
    return false;
  }
}

/**
 * Live preview shown *below* a display-math block when the cursor is
 * inside it. Source stays visible above; this widget renders the
 * current LaTeX so the user sees the rendered form while editing.
 *
 * `lastValidHtml` is used as the displayed HTML when KaTeX returns
 * null on the current source (typically a mid-keystroke invalid
 * state). This prevents the preview from flickering to "error" and
 * back as the user types.
 */
class MathPreviewWidget extends WidgetType {
  constructor(
    private readonly content: string,
    private readonly lastValidHtml: string,
    private readonly cache: KaTeXCache,
  ) {
    super();
  }

  eq(other: MathPreviewWidget): boolean {
    return (
      this.content === other.content &&
      this.lastValidHtml === other.lastValidHtml
    );
  }

  toDOM(): HTMLElement {
    const host = document.createElement('div');
    host.className = 'cm-tex-math-preview';
    host.setAttribute('contenteditable', 'false');
    const html = this.cache.render(this.content, true);
    host.innerHTML = html ?? this.lastValidHtml;
    return host;
  }

  ignoreEvent(): boolean {
    // Preview is read-only; ignore all events so clicks/keys reach the
    // source above, which is where the cursor lives.
    return true;
  }
}

/**
 * LRU of last successfully rendered HTML per source string. Bounded to
 * avoid unbounded growth across long sessions; size 100 covers any
 * realistic editing burst on a single document.
 */
const MAX_LAST_VALID = 100;
const lastValidRenders = new Map<string, string>();

function rememberValidRender(content: string, html: string): void {
  lastValidRenders.delete(content);
  lastValidRenders.set(content, html);
  if (lastValidRenders.size > MAX_LAST_VALID) {
    const oldest = lastValidRenders.keys().next().value;
    if (oldest !== undefined) lastValidRenders.delete(oldest);
  }
}

/**
 * Build decorations for all math regions in the document. A region renders
 * as a MathWidget unless the cursor sits inside it, in which case we leave
 * the raw LaTeX visible for editing.
 *
 * Runs over the whole document (not just the viewport) because CM6 requires
 * block decorations to be provided via a StateField, which doesn't have
 * access to the view's visibleRanges. `scanMathRegions` is O(n) and the
 * KaTeX results are cached, so re-scanning on every transaction is cheap.
 */
function buildDecorations(
  state: EditorState,
  cache: KaTeXCache,
): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const cursor = state.selection.main.head;
  const regions = scanMathRegions(state.doc.toString());

  for (const r of regions) {
    const cursorInside = cursor >= r.from && cursor <= r.to;

    if (cursorInside) {
      // Source stays visible. For display math, drop a live preview
      // widget right after the closing delimiter so the user sees the
      // rendered form while editing. Inline math gets no preview —
      // an inline render below the source would shove surrounding
      // text around on every keystroke.
      if (r.display) {
        const html = cache.render(r.content, true);
        if (html) rememberValidRender(r.content, html);
        const lastValid = html ?? lastValidRenders.get(r.content) ?? '';
        builder.add(
          r.to,
          r.to,
          Decoration.widget({
            widget: new MathPreviewWidget(r.content, lastValid, cache),
            block: true,
            side: 1,
          }),
        );
      }
      continue;
    }

    // Cursor outside: replace the entire region with a rendered widget.
    builder.add(
      r.from,
      r.to,
      Decoration.replace({
        widget: new MathWidget(r.content, r.display, cache),
        block: r.display,
      }),
    );
  }

  return builder.finish();
}

/**
 * CM6 enforces that block replace decorations may only be supplied by a
 * StateField, not a ViewPlugin (block geometry feeds the viewport
 * measurement pass, which runs before view plugins). So we use a StateField
 * even for inline math — a single field that owns both kinds keeps the
 * pass-order and atomicRanges story simple.
 */
export function texMathPlugin(): Extension {
  const cache = new KaTeXCache();

  return StateField.define<DecorationSet>({
    create(state) {
      return buildDecorations(state, cache);
    },
    update(decos, tr) {
      if (!tr.docChanged && !tr.selection) return decos;
      return buildDecorations(tr.state, cache);
    },
    provide: (field) => [
      EditorView.decorations.from(field),
      EditorView.atomicRanges.of((view) => view.state.field(field)),
    ],
  });
}
