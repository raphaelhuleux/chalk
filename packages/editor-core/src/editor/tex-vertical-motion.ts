import { EditorState, Extension } from '@codemirror/state';
import { mathRegionsOf } from './tex-math';
import { styleRegionsFor } from './tex-decorations';
import { concealedShape } from './tex-conceal-plugin';
import { makeVerticalArrowKeymap } from './callout-core';
import { regionAt } from './display-math-core';
import { isPreviewMode } from './view-mode';

// Vertical caret motion over concealed constructs. Two traps:
//
// 1. A landing inside a widget (inline math, pills) would reveal it and reflow
//    the line mid-navigation, so landings snap to the nearest edge. A landing
//    in a hidden `\command{` prefix snaps to the first visible character;
//    visible argument text is a real landing. Mixed hides no command syntax,
//    so there only math snaps.
// 2. CM6's goalColumn doesn't survive a dispatch, so the column would ratchet
//    toward 0 over short lines and fences. The keymap owns the whole move and
//    aims at callout-core's verticalGoalX, which persists across presses.
//
// Caret geometry isn't testable in jsdom: extend the Tests/ harnesses when
// changing this.

/** Nearest position OUTSIDE `[from, end)`: `from - 1` (`from` itself is inside
 *  every reveal predicate) or `end`; `end` when `from - 1` would leave the line. */
function nearestEdge(state: EditorState, pos: number, from: number, end: number): number {
  const left = from - 1;
  if (left < state.doc.lineAt(from).from) return end;
  return pos - from <= end - pos ? left : end;
}

/** One snap pass: where a landing at `pos` should settle, or null. */
function snapOnce(state: EditorState, pos: number): number | null {
  const m = regionAt(mathRegionsOf(state), pos);
  // Display math reveals by line; its block widgets have their own keymap.
  if (m && !m.display) return nearestEdge(state, pos, m.from, m.to);

  if (!isPreviewMode(state)) return null;
  // Keep the LAST match so nested constructs resolve to the innermost prefix.
  let snapped: number | null = null;
  for (const r of styleRegionsFor(state)) {
    if (pos < r.cmdFrom || pos > r.to) continue;
    const shape = concealedShape(state, r);
    if (shape === 'whole') {
      snapped = nearestEdge(state, pos, r.cmdFrom, r.to + 1);
    } else if (shape === 'delimiters' && pos < r.from) {
      snapped = r.from;
    }
  }
  return snapped;
}

/**
 * Where a vertical landing at `pos` should settle, or null. Iterates snapOnce
 * to a fixpoint: in `\textbf{\emph{xy}}` the outer argument starts with the
 * inner hidden prefix, so one pass could settle inside it. `seen` stops an
 * oscillation between nearestEdge and a forward snap.
 */
export function snapVerticalLanding(state: EditorState, pos: number): number | null {
  const seen = new Set<number>([pos]);
  let cur = pos;
  for (;;) {
    const next = snapOnce(state, cur);
    if (next === null || seen.has(next)) break;
    seen.add(next);
    cur = next;
  }
  return cur === pos ? null : cur;
}

/**
 * Owns default Up/Down for an empty caret outside source mode (see
 * makeVerticalArrowKeymap), snapping the landing out of widget-rendered
 * regions.
 */
export function texVerticalArrowKeymap(
  sourceModeActive: (state: EditorState) => boolean,
): Extension {
  return makeVerticalArrowKeymap({ sourceModeActive, snap: snapVerticalLanding });
}
