import { EditorSelection, Prec, type EditorState } from '@codemirror/state';
import { keymap, type Command } from '@codemirror/view';

/**
 * Cmd+B / Cmd+I toggle: unwrap when the markers sit inside the selection
 * (`[**world**]`) or just outside it (`**[world]**`, or a caret in an empty
 * `**|**`), else wrap. `isMarked` must also hold to unwrap: markdown's bold
 * and italic share `*`, so the markers alone can't tell them apart.
 */
function wrapCommand(
  before: string,
  after: string,
  isMarked?: (state: EditorState, from: number, to: number) => boolean,
): Command {
  return (view) => {
    const { state } = view;
    const spec = state.changeByRange((range) => {
      const selected = state.sliceDoc(range.from, range.to);

      const marked = !isMarked || isMarked(state, range.from, range.to);
      const wrapped =
        marked &&
        !range.empty &&
        selected.length >= before.length + after.length &&
        selected.startsWith(before) &&
        selected.endsWith(after);

      if (wrapped) {
        const inner = selected.slice(before.length, selected.length - after.length);
        return {
          changes: { from: range.from, to: range.to, insert: inner },
          range: EditorSelection.range(range.from, range.from + inner.length),
        };
      }

      // Markers just OUTSIDE: re-pressing must toggle off, not nest. Peels
      // ONE layer: `***word***` un-bolds to `*word*`.
      const beforeStart = range.from - before.length;
      const afterEnd = range.to + after.length;
      if (
        marked &&
        beforeStart >= 0 &&
        afterEnd <= state.doc.length &&
        state.sliceDoc(beforeStart, range.from) === before &&
        state.sliceDoc(range.to, afterEnd) === after
      ) {
        return {
          changes: [
            { from: beforeStart, to: range.from },
            { from: range.to, to: afterEnd },
          ],
          range: range.empty
            ? EditorSelection.cursor(beforeStart)
            : EditorSelection.range(beforeStart, beforeStart + selected.length),
        };
      }

      const insert = before + selected + after;
      const anchor = range.from + before.length;
      return {
        changes: { from: range.from, to: range.to, insert },
        range: range.empty
          ? EditorSelection.cursor(anchor)
          : EditorSelection.range(anchor, anchor + selected.length),
      };
    });

    view.dispatch(state.update(spec, { scrollIntoView: true, userEvent: 'input.format' }));
    return true;
  };
}

// Prec.high: defaultKeymap's Mod-i (selectParentSyntax) succeeds wherever a
// parse tree exists, so it would swallow Cmd+I in markdown.

/** The `*` run around `from..to` (counting any `*` at the range's own edges):
 *  the shorter of the runs on either side of the text it wraps. */
function starRun(state: EditorState, from: number, to: number): number {
  const at = (pos: number) => state.sliceDoc(pos, pos + 1) === '*';
  let a = from;
  while (a < to && at(a)) a++;
  let b = to;
  while (b > a && at(b - 1)) b--;
  let left = 0;
  while (a - left > 0 && at(a - left - 1)) left++;
  let right = 0;
  while (b + right < state.doc.length && at(b + right)) right++;
  return Math.min(left, right);
}

/** Markdown: `**bold**` / `*italic*`. A run of 1 or 3 `*` is italic and 2 or
 *  3 is bold, so the inner `*` of `**word**` doesn't read as italic. */
export const mdFormatKeymap = Prec.high(
  keymap.of([
    { key: 'Mod-b', run: wrapCommand('**', '**', (s, f, t) => starRun(s, f, t) >= 2) },
    { key: 'Mod-i', run: wrapCommand('*', '*', (s, f, t) => starRun(s, f, t) % 2 === 1) },
  ]),
);

/** LaTeX: `\textbf{bold}` / `\textit{italic}`. */
export const texFormatKeymap = Prec.high(
  keymap.of([
    { key: 'Mod-b', run: wrapCommand('\\textbf{', '}') },
    { key: 'Mod-i', run: wrapCommand('\\textit{', '}') },
  ]),
);
