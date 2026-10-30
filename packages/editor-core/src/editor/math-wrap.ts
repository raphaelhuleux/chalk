import {
  EditorSelection,
  EditorState,
  Extension,
  Prec,
} from '@codemirror/state';
import { EditorView } from '@codemirror/view';

/**
 * Typing one of these over a non-empty selection inside math wraps it instead
 * of replacing it: `(` and `[` in `\left(…\right)` rather than closeBrackets'
 * plain pair, `/` in a fraction, `^` and `_` in a script, `U` and `O` in an
 * underbrace or overbrace with the caret on its label. Empty selections and
 * non-math positions fall through, so autopairing and the `;(` / `;[` hsnips
 * still fire. The selection stays on the original text, like closeBrackets;
 * `next` instead puts the caret that far before the end, in the next slot.
 */
const WRAPS: Record<string, { open: string; close: string; next?: number }> = {
  '(': { open: '\\left(', close: '\\right)' },
  '[': { open: '\\left[', close: '\\right]' },
  '/': { open: '\\frac{', close: '}{}', next: 1 },
  '^': { open: '^{', close: '}', next: 0 },
  _: { open: '_{', close: '}', next: 0 },
  U: { open: '\\underbrace{', close: '}_{}', next: 1 },
  O: { open: '\\overbrace{', close: '}^{}', next: 1 },
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
  const inserted = wrap.open + original + wrap.close;
  const innerFrom = from + wrap.open.length;
  const innerTo = innerFrom + original.length;

  view.dispatch({
    changes: { from, to, insert: inserted },
    selection:
      wrap.next === undefined
        ? EditorSelection.range(innerFrom, innerTo)
        : EditorSelection.cursor(from + inserted.length - wrap.next),
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
