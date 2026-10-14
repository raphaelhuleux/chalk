import {
  EditorSelection,
  EditorState,
  Extension,
  Prec,
} from '@codemirror/state';
import { EditorView } from '@codemirror/view';

/**
 * Typing `(` or `[` over a non-empty selection inside math wraps it in
 * `\left(…\right)` instead of closeBrackets' plain pair. Empty selections and
 * non-math positions fall through, so autopairing and the `;(` / `;[` hsnips
 * still fire. The selection stays on the original text, like closeBrackets.
 */
const WRAPS: Record<string, [string, string]> = {
  '(': ['\\left(', '\\right)'],
  '[': ['\\left[', '\\right]'],
};

/**
 * Dispatches the wrap and returns true if the inputs qualify, else false so
 * CM6 falls through to the next handler.
 *
 * Both ends must be in math, or a half-in selection yields `\left( ... $b\right)$`.
 * The end is tested at `to - 1`, the last selected character.
 */
export function tryMathWrap(
  view: EditorView,
  from: number,
  to: number,
  text: string,
  isInMathContext: (state: EditorState, pos: number) => boolean,
): boolean {
  const wrap = WRAPS[text];
  if (!wrap) return false;
  if (from === to) return false;
  if (!isInMathContext(view.state, from)) return false;
  if (!isInMathContext(view.state, to - 1)) return false;

  const original = view.state.sliceDoc(from, to);
  const inserted = wrap[0] + original + wrap[1];
  const innerFrom = from + wrap[0].length;
  const innerTo = innerFrom + original.length;

  view.dispatch({
    changes: { from, to, insert: inserted },
    selection: EditorSelection.range(innerFrom, innerTo),
    userEvent: 'input.type',
  });
  return true;
}

export function mathWrapInputHandler(
  isInMathContext: (state: EditorState, pos: number) => boolean,
): Extension {
  return Prec.high(
    EditorView.inputHandler.of((view, from, to, text) =>
      tryMathWrap(view, from, to, text, isInMathContext),
    ),
  );
}
