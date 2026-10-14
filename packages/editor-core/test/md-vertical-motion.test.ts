import { describe, it, expect, afterEach } from 'vitest';
import { EditorView } from '@codemirror/view';
import { EditorSelection } from '@codemirror/state';
import { _testing as mdArrows } from '../src/editor/md-math-plugin';
import { destroyViews, mdView } from './helpers/views';

// ---------------------------------------------------------------------------
// Vertical caret motion in markdown.
//
// The tex branch has owned Up/Down since tex-vertical-motion.ts; markdown kept
// CM6's defaults and inherited two defects, both reported as "the caret
// jumped somewhere I did not aim at":
//
//   1. `mdMathArrowKeymap` fires on DOCUMENT-line adjacency, so a soft-wrapped
//      paragraph directly above a `$$` block teleported into the math on the
//      first Down instead of walking its own visual rows. Covered here.
//   2. Every stop that dispatches its own landing reset the goal column, which
//      then never recovered. That one needs real layout — see the
//      "md: Up/Down keeps the goal column across a display-math stop"
//      scenario in Tests/browser/run.mjs.
//
// Note what is deliberately NOT here: a landing-inside-a-widget snap like the
// tex side's. CM6 clamps posAtCoords to a replace widget's edges, so a
// vertical landing cannot fall inside an `$…$` widget (probed against the
// built bundle); tex's snap exists for its hidden `\command{` prefixes, which
// markdown has no equivalent of.
// ---------------------------------------------------------------------------

afterEach(destroyViews);

// ---------------------------------------------------------------------------
// Wrapped-line deference for the display-math entry keymap.
//
// `mdMathArrowKeymap` fires on plain DOCUMENT-LINE adjacency. On a soft-wrapped
// paragraph sitting directly above a `$$` block that is wrong: the first Down
// press should walk to the paragraph's next VISUAL row, not teleport into the
// math. The tex twin has deferred via `moreWrappedRows` since it was written;
// markdown never did (live-reported symptom: "Down jumps into the equation").
//
// jsdom has no layout, so `coordsAtPos` returns null and `moreWrappedRows`
// answers false by design. These tests stub the two geometry calls it makes,
// which is exactly the seam the guard reads.
// ---------------------------------------------------------------------------

const mountView = (docText: string, cursor: number): EditorView => mdView(docText, { cursor });

/** Make `moreWrappedRows` answer true: a measurable caret whose default
 *  vertical move stays on the same document line (an inner wrapped row). */
function stubWrappedRow(view: EditorView, landing: number) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (view as any).coordsAtPos = () => ({ left: 10, right: 11, top: 0, bottom: 12 });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (view as any).moveVertically = () => EditorSelection.cursor(landing);
}

describe('md display-math entry defers to wrapped rows', () => {
  // No blank line is needed before `$$` (verified against the md parser), so a
  // soft-wrapped paragraph really can sit on the document line directly above
  // a display block — the case the guard exists for.
  const doc = 'wrapped paragraph text that soft wraps\n$$\n\\alpha\n$$\ntrailing prose that also wraps';
  const openFence = doc.indexOf('$$');
  const closeFence = doc.lastIndexOf('$$');

  it('Down does not enter the math while wrapped rows remain below', () => {
    const view = mountView(doc, 0);
    stubWrappedRow(view, 10); // same document line → an inner wrapped row
    expect(mdArrows.mdEnterDisplayMathFromAbove(view)).toBe(false);
    expect(view.state.selection.main.head).toBe(0);
  });

  it('Down still enters the math from the last wrapped row', () => {
    const view = mountView(doc, 0);
    stubWrappedRow(view, openFence); // a DIFFERENT document line: no rows left
    expect(mdArrows.mdEnterDisplayMathFromAbove(view)).toBe(true);
    expect(view.state.selection.main.head).toBe(openFence);
  });

  it('Up does not enter the math while wrapped rows remain above', () => {
    const below = closeFence + 3; // inside the trailing paragraph
    const view = mountView(doc, below + 5);
    stubWrappedRow(view, below); // same document line
    expect(mdArrows.mdEnterDisplayMathFromBelow(view)).toBe(false);
  });

  it('Up still enters the math from the first wrapped row', () => {
    const view = mountView(doc, closeFence + 3);
    stubWrappedRow(view, closeFence); // a DIFFERENT document line
    expect(mdArrows.mdEnterDisplayMathFromBelow(view)).toBe(true);
    expect(view.state.selection.main.head).toBe(closeFence);
  });
});
