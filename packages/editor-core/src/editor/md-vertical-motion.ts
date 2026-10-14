import { EditorView } from '@codemirror/view';
import { EditorState, Extension } from '@codemirror/state';
import { makeVerticalArrowKeymap } from './callout-core';

// Markdown vertical motion keeps its goal column. CM6's goalColumn does not
// survive a dispatch, so the keymaps that stop a run (mdCalloutFenceKeymap,
// mdMathArrowKeymap) would reset it. This keymap aims each press at the
// goal-session x (verticalGoalX), which those stops keep alive.
//
// Unlike tex-vertical-motion.ts there is no landing snap: CM6 clamps
// posAtCoords to a replace widget's edges, so a landing can't fall inside a
// `$…$` widget. The tex snap exists for hidden `\command{` prefixes.

/**
 * Probe distance past the rendered row of a paragraph-interior `$$…$$`
 * (KaTeXInlineDisplayWidget), or undefined for CM6's default. That inline
 * widget fills a whole row, so the default probe lands on it and resolves to
 * an edge; the start edge is inside the reveal window, so Up revealed the
 * equation and lost the column. Probing past the row lands on the prose beyond.
 */
function pastInlineDisplayRow(
  view: EditorView,
  head: number,
  assoc: number,
  forward: boolean,
): number | undefined {
  const caret = view.coordsAtPos(head, assoc < 0 ? -1 : 1);
  if (!caret) return undefined;
  const edge = forward ? caret.bottom : caret.top;
  const reach = view.defaultLineHeight;
  for (const row of view.contentDOM.querySelectorAll('.cm-math-inline-display-row')) {
    const r = row.getBoundingClientRect();
    const adjacent = forward
      ? r.top >= edge - 1 && r.top < edge + reach
      : r.bottom <= edge + 1 && r.bottom > edge - reach;
    if (adjacent) return (forward ? r.bottom - edge : edge - r.top) + 2;
  }
  return undefined;
}

/**
 * Owns default Up/Down for an empty caret outside source mode (see
 * makeVerticalArrowKeymap), probing past a paragraph-interior `$$…$$` row.
 */
export function mdVerticalArrowKeymap(
  sourceModeActive: (state: EditorState) => boolean,
): Extension {
  return makeVerticalArrowKeymap({ sourceModeActive, probe: pastInlineDisplayRow });
}
