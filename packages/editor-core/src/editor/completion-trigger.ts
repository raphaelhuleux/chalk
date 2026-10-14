import { EditorState, Extension } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { completionStatus, startCompletion } from '@codemirror/autocomplete';

/**
 * Open the completion popup when the caret MOVES into an empty argument slot
 * (e.g. the `()` of `![]()`): CM6 only activates on `input.type`, which a
 * caret move lacks.
 *
 * Deliberately narrow: only an EMPTY slot with its closer right after the
 * caret, so moving into existing content or a line-start source (fences,
 * frontmatter keys) stays quiet. `offerCompletionsAtStop` in hsnips-plugin
 * is broad on purpose: landing on a tab stop is the "fill this in" moment.
 */
type EmptyArgumentTest = (state: EditorState, pos: number) => boolean;

export function emptyArgumentCompletion(isEmptyArgument: EmptyArgumentTest): Extension {
  return EditorView.updateListener.of((update) => {
    // Selection-only: typing and snippet inserts offer their own lists.
    if (update.docChanged || !update.selectionSet) return;

    const selection = update.state.selection.main;
    if (!selection.empty) return;
    // A click on the caret's own spot or a focus round-trip is not a move.
    if (update.startState.selection.main.head === selection.head) return;
    // Already open: let the user's own filtering stand.
    if (completionStatus(update.state) !== null) return;
    if (!isEmptyArgument(update.state, selection.head)) return;

    startCompletion(update.view);
  });
}

/** Whether `pos` sits in an empty slot: `opening` matches the line up to
 *  `pos` and `closer` is the next char. */
export function emptySlotAt(
  state: EditorState,
  pos: number,
  opening: RegExp,
  closer: string,
): boolean {
  const line = state.doc.lineAt(pos);
  const offset = pos - line.from;
  if (line.text[offset] !== closer) return false;
  return opening.test(line.text.slice(0, offset));
}
