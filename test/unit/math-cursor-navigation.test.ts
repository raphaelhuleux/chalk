import { describe, it, expect, beforeAll } from 'vitest';
import { EditorView } from '@codemirror/view';
import { EditorState, EditorSelection } from '@codemirror/state';
import { cursorCharLeft, cursorCharRight } from '@codemirror/commands';
import { StreamLanguage, ensureSyntaxTree } from '@codemirror/language';
import { stex } from '@codemirror/legacy-modes/mode/stex';
import { markdown } from '@codemirror/lang-markdown';
import { texMathPlugin, _testing as texArrows } from '../../src/webview/editor/tex-math';
import {
  mathPlugin,
  mathSyntax,
  _testing as mdArrows,
} from '../../src/webview/editor/md-math-plugin';

/**
 * jsdom can't measure visual-line geometry, so we can't drive
 * cursorLineDown / Up directly in tests. Instead, assert the
 * structural property that *causes* the navigation bug: whether
 * the atomicRanges facet reports the math interior as atomic.
 *
 * If no atomic range covers position `pos`, then arrow-key navigation
 * landing the cursor at `pos` will succeed (CM6 has nothing to push
 * it out of the way). That's the bugfix invariant we care about.
 */
function isPositionAtomic(view: EditorView, pos: number): boolean {
  const providers = view.state.facet(EditorView.atomicRanges);
  for (const provide of providers) {
    const set = provide(view);
    let hit = false;
    set.between(pos, pos, (from, to) => {
      if (from < pos && to > pos) {
        hit = true;
        return false;
      }
    });
    if (hit) return true;
  }
  return false;
}

// jsdom doesn't implement Range.getClientRects / getBoundingClientRect.
// CM6 schedules a measure pass on view creation that calls these. The
// pass result is unused by these tests (we query state, not geometry),
// so stub to no-ops to keep "unhandled errors" from failing the run.
beforeAll(() => {
  if (typeof Range.prototype.getClientRects !== 'function') {
    Range.prototype.getClientRects = () => [] as unknown as DOMRectList;
  }
  if (typeof Range.prototype.getBoundingClientRect !== 'function') {
    Range.prototype.getBoundingClientRect = () =>
      ({ x: 0, y: 0, width: 0, height: 0, top: 0, right: 0, bottom: 0, left: 0, toJSON: () => ({}) }) as DOMRect;
  }
});

function makeTexView(doc: string, cursor: number): EditorView {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  const state = EditorState.create({
    doc,
    selection: EditorSelection.cursor(cursor),
    extensions: [StreamLanguage.define(stex), texMathPlugin()],
  });
  return new EditorView({ state, parent });
}

function makeMdView(doc: string, cursor: number): EditorView {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  const state = EditorState.create({
    doc,
    selection: EditorSelection.cursor(cursor),
    extensions: [
      markdown({ extensions: [mathSyntax] }),
      mathPlugin(),
    ],
  });
  // Force full parse so DisplayMath nodes exist.
  ensureSyntaxTree(state, state.doc.length, 5000);
  return new EditorView({ state, parent });
}

describe('tex math cursor navigation', () => {
  it('Left from immediately after $x^2$ lands just inside the closing $', () => {
    // 'abc $x^2$' — math at offsets 4..9 (r.from=4, r.to=9)
    //  0   45678 9
    const doc = 'abc $x^2$';
    const view = makeTexView(doc, doc.length);
    cursorCharLeft(view);
    expect(view.state.selection.main.head).toBe(doc.length - 1);
    view.destroy();
  });

  it('Right from immediately before $x^2$ lands just inside the opening $', () => {
    // 'abc $x^2$ d' — math at 4..9
    const doc = 'abc $x^2$ d';
    const view = makeTexView(doc, 4); // just before opening $
    cursorCharRight(view);
    expect(view.state.selection.main.head).toBe(5);
    view.destroy();
  });

  it('does not mark a collapsed $$..$$ block as atomic (allows arrow-into-block)', () => {
    // Layout: 'abc\n$$\n\\alpha\n$$\ndef'
    //   abc  \n=3
    //   $$   from=4, the second $$ closes at 14..15, region.to=16
    //   \alpha
    //   $$
    //   def  starts at 17
    const doc = 'abc\n$$\n\\alpha\n$$\ndef';
    // Cursor on 'def' line — outside math, so it's collapsed.
    const view = makeTexView(doc, 17);
    // A position deep inside the math source should NOT be reported as
    // atomic. With atomic, CM6 skips the entire block on Down/Up.
    expect(isPositionAtomic(view, 8)).toBe(false); // inside '\alpha'
    expect(isPositionAtomic(view, 5)).toBe(false); // between the two $ of opening
    view.destroy();
  });

  it('does not mark a collapsed inline $..$ as atomic (allows Left-into-span)', () => {
    // 'abc $x^2$ end' — math at 4..9, cursor far away on 'end'
    const doc = 'abc $x^2$ end';
    const view = makeTexView(doc, doc.length);
    expect(isPositionAtomic(view, 6)).toBe(false); // mid-content '^'
    expect(isPositionAtomic(view, 8)).toBe(false); // before closing $
    view.destroy();
  });
});

describe('md math cursor navigation', () => {
  it('Left from immediately after inline $x^2$ lands just inside the closing $', () => {
    // Markdown inline math is NOT registered as an atomic range,
    // so this should already pass on main.
    const doc = 'abc $x^2$';
    const view = makeMdView(doc, doc.length);
    cursorCharLeft(view);
    expect(view.state.selection.main.head).toBe(doc.length - 1);
    view.destroy();
  });

  it('does not mark a collapsed display $$..$$ block as atomic', () => {
    // Markdown needs a blank line before $$ for the block parser to
    // recognise it. Layout:
    //   abc\n\n$$\n\\alpha\n$$\n\ndef
    const doc = 'abc\n\n$$\n\\alpha\n$$\n\ndef';
    const view = makeMdView(doc, doc.length); // cursor on 'def', math collapsed
    // A position inside the math source should not be atomic.
    // Find a safe interior position — on '\alpha' line.
    const alphaPos = doc.indexOf('\\alpha') + 2;
    expect(isPositionAtomic(view, alphaPos)).toBe(false);
    view.destroy();
  });
});

describe('Down/Up keymap entry into collapsed display math', () => {
  it('tex: Down from line above $$..$$ lands at end of opening line', () => {
    // 'abc\n$$\n\\alpha\n$$\ndef'
    //  ^line1 ^line2 ^line3  ^line4 ^line5
    //  positions: abc=0..3, $$=4..6, \alpha=7..13, $$=14..16, def=17..19
    const doc = 'abc\n$$\n\\alpha\n$$\ndef';
    const view = makeTexView(doc, 0); // cursor at start of 'abc' line
    const handled = texArrows.enterDisplayMathFromAbove(view);
    expect(handled).toBe(true);
    // End of opening $$ line = position 6 (the \n after $$).
    expect(view.state.selection.main.head).toBe(6);
    view.destroy();
  });

  it('tex: Up from line below $$..$$ lands at start of closing line', () => {
    const doc = 'abc\n$$\n\\alpha\n$$\ndef';
    const view = makeTexView(doc, 17); // cursor at start of 'def' line
    const handled = texArrows.enterDisplayMathFromBelow(view);
    expect(handled).toBe(true);
    // Start of closing $$ line = position 14.
    expect(view.state.selection.main.head).toBe(14);
    view.destroy();
  });

  it('tex: Down from a line not directly above any math is a no-op', () => {
    const doc = 'abc\n\nmore\n$$\nx\n$$\ndef';
    const view = makeTexView(doc, 0); // 'abc' line — math is two lines below
    const handled = texArrows.enterDisplayMathFromAbove(view);
    expect(handled).toBe(false);
    expect(view.state.selection.main.head).toBe(0); // unchanged
    view.destroy();
  });

  it('tex: Down handler does not fire when cursor is already inside math', () => {
    const doc = 'abc\n$$\n\\alpha\n$$\ndef';
    const view = makeTexView(doc, 8); // cursor inside math source
    const handled = texArrows.enterDisplayMathFromAbove(view);
    expect(handled).toBe(false);
    view.destroy();
  });

  it('md: Down from line above $$..$$ enters the display block', () => {
    // Markdown requires a blank line before $$. Doc layout:
    //   abc          line 1
    //                line 2 (blank)
    //   $$           line 3 (math start)
    //   \alpha       line 4
    //   $$           line 5 (math end)
    //                line 6 (blank)
    //   def          line 7
    const doc = 'abc\n\n$$\n\\alpha\n$$\n\ndef';
    // Cursor on the blank line directly above $$.
    const blankBeforeMath = 4; // position of the blank-line \n
    const view = makeMdView(doc, blankBeforeMath);
    const handled = mdArrows.mdEnterDisplayMathFromAbove(view);
    expect(handled).toBe(true);
    // End of opening-$$ line. The opening $$ line spans positions 5..7
    // ($-$-\n). Its .to is the position of the \n = 7.
    expect(view.state.selection.main.head).toBe(7);
    view.destroy();
  });

  it('md: Up from line below $$..$$ enters the display block', () => {
    const doc = 'abc\n\n$$\n\\alpha\n$$\n\ndef';
    // Cursor on the blank line directly below $$ (line 6).
    const blankAfterMath = doc.indexOf('\n\ndef') + 1; // start of blank line
    const view = makeMdView(doc, blankAfterMath);
    const handled = mdArrows.mdEnterDisplayMathFromBelow(view);
    expect(handled).toBe(true);
    // Start of closing-$$ line.
    const closingDollar = doc.lastIndexOf('$$');
    expect(view.state.selection.main.head).toBe(closingDollar);
    view.destroy();
  });
});
