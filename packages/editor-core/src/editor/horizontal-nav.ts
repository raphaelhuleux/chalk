// Self-correcting line-boundary motion (Home/End, Cmd+Left/Right on mac).
// CM's moveToLineBoundary hit-tests with posAtCoords, which in WebKit can
// overshoot onto another logical line near block widgets (tables, display math)
// or at the tail of long wrapped lines. When it leaves the line, recompute the
// visual-row boundary within the line using pos-to-coords, the reliable
// direction; otherwise defer to the default. Cmd+Arrow is mac-only because a
// Mod- binding would shadow Ctrl+Arrow word motion elsewhere.

import { EditorView, KeyBinding, keymap } from '@codemirror/view';
import { EditorSelection, Extension, Prec } from '@codemirror/state';

type Band = { top: number; bottom: number } | null;

function sameRow(a: NonNullable<Band>, b: NonNullable<Band>): boolean {
  return a.top < b.bottom && b.top < a.bottom;
}

/**
 * Start or end (`forward`) of `head`'s visual row, binary-searched within
 * [from, to] (row tops are monotonic). Falls back to the logical boundary when
 * `rowAt(head)` is null. Exported for tests: jsdom has no layout.
 */
export function rowBoundaryPos(
  from: number,
  to: number,
  head: number,
  forward: boolean,
  rowAt: (pos: number) => Band,
): number {
  const anchor = rowAt(head);
  if (!anchor) return forward ? to : from;

  if (forward) {
    let lo = head, hi = to;
    while (lo < hi) {
      const mid = lo + ((hi - lo + 1) >> 1); // upper mid, biased to the end
      const c = rowAt(mid);
      if (c && sameRow(c, anchor)) lo = mid;
      else hi = mid - 1;
    }
    return lo;
  }

  let lo = from, hi = head;
  while (lo < hi) {
    const mid = lo + ((hi - lo) >> 1);
    const c = rowAt(mid);
    if (c && sameRow(c, anchor)) hi = mid;
    else lo = mid + 1;
  }
  return lo;
}

function lineBoundary(forward: boolean, extend: boolean) {
  return (view: EditorView): boolean => {
    const { state } = view;
    const range = state.selection.main;

    let coordResult;
    try {
      coordResult = view.moveToLineBoundary(range, forward);
    } catch {
      return false; // no layout (jsdom): let the default run
    }

    const line = state.doc.lineAt(range.head);
    if (state.doc.lineAt(coordResult.head).number === line.number) return false;

    // The side makes a wrap-boundary position resolve to the caret's row.
    const rowAt = (pos: number): Band => view.coordsAtPos(pos, forward ? -1 : 1);
    let target = rowBoundaryPos(line.from, line.to, range.head, forward, rowAt);

    // Mirror CM: backward stops at the first non-space before column 0.
    if (!forward && target === line.from) {
      const indent = /^\s*/.exec(line.text)![0].length;
      const firstNonSpace = line.from + indent;
      if (indent > 0 && range.head !== firstNonSpace) target = firstNonSpace;
    }

    view.dispatch({
      selection: extend
        ? EditorSelection.range(range.anchor, target)
        : EditorSelection.cursor(target),
      scrollIntoView: true,
      userEvent: 'select',
    });
    return true;
  };
}

/** Exported for the wiring test. */
export const horizontalNavBindings: readonly KeyBinding[] = [
  // No preventDefault: returning false must reach the default command.
  { key: 'Home', run: lineBoundary(false, false), shift: lineBoundary(false, true) },
  { key: 'End', run: lineBoundary(true, false), shift: lineBoundary(true, true) },
  { mac: 'Cmd-ArrowLeft', run: lineBoundary(false, false), shift: lineBoundary(false, true) },
  { mac: 'Cmd-ArrowRight', run: lineBoundary(true, false), shift: lineBoundary(true, true) },
];

export const horizontalNavKeymap: Extension = Prec.high(keymap.of(horizontalNavBindings));
