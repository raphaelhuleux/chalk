import { EditorState } from '@codemirror/state';

/**
 * Keeps trailing punctuation on the row of the construct it follows.
 *
 * Rendered formulas (`inline-block`) and CM6's `<img class="cm-widgetBuffer">`
 * are atomic inlines, which CSS may wrap on either side even without
 * whitespace, stranding the `!` after `$V_t(a)$` on the next row. The cure is
 * a `white-space: nowrap` mark over construct plus punctuation; it leaves the
 * widget's `display` alone (the `inline-block` is a WKWebView repaint fix,
 * see editor.css).
 *
 * The mark must be `Decoration.mark({ inclusiveStart: true })` (startSide -1,
 * ahead of a replace's): CM6 sorts by (`from`, `startSide`) and a mark only
 * wraps a replace it opens before. A plain mark makes RangeSetBuilder throw,
 * and CM6 drops the whole plugin.
 */
const GLUE_CHARS = new Set(['!', '?', '.', ',', ';', ':', ')', ']', '}', '"', "'", '”', '’']);

/** A longer run than this is not punctuation clinging to a word. */
const GLUE_MAX = 3;

/** How far past `to` a glue mark should reach (at most `GLUE_MAX` glue chars,
 *  same line); `to` when there is nothing to glue. */
export function glueEnd(state: EditorState, to: number): number {
  const lineEnd = state.doc.lineAt(to).to;
  let end = to;
  while (
    end < lineEnd &&
    end - to < GLUE_MAX &&
    GLUE_CHARS.has(state.doc.sliceString(end, end + 1))
  ) {
    end++;
  }
  return end;
}

/**
 * Where a glue mark must start: the beginning of the last word before
 * `before`, not before `floor`. A box that opened on an atomic `<img>` would
 * keep the wrap opportunity before it, stranding the punctuation anyway.
 */
export function glueStart(state: EditorState, before: number, floor: number): number {
  const lineFrom = state.doc.lineAt(before).from;
  let start = before;
  while (start > floor && start > lineFrom && !/\s/.test(state.doc.sliceString(start - 1, start))) {
    start--;
  }
  return start;
}
