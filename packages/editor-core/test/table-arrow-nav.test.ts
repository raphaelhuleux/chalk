import { describe, it, expect, beforeEach } from 'vitest';
import { EditorSelection } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { _testing } from '../src/editor/table-field';
import { mdView } from './helpers/views';

/**
 * Vertical cursor/selection motion across a table block. A rendered table is a
 * tall atomic block widget; CM6's coordinate-based moveVertically scans past
 * its whole height in one keypress (skipping the table, sometimes more than
 * one). The table-aware arrow keymap must move exactly one table per press and
 * land on the adjacent line.
 *
 * Doc line map (1-based):
 *   1 alpha
 *   2 beta
 *   3 (blank)
 *   4 | h1 | h2 |   <- table A start
 *   5 | -- | -- |
 *   6 | r1 | r2 |   <- table A end
 *   7 (blank)
 *   8 gamma
 */
const DOC = 'alpha\nbeta\n\n| h1 | h2 |\n| -- | -- |\n| r1 | r2 |\n\ngamma';

function press(view: EditorView, key: string, shift: boolean) {
  view.contentDOM.dispatchEvent(
    new KeyboardEvent('keydown', { key, shiftKey: shift, bubbles: true, cancelable: true }),
  );
}

describe('table-aware vertical navigation', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  // ensureTree: the table keymap reads Table nodes from the syntax tree;
  // without a guaranteed full parse the handler occasionally saw no table and
  // fell through to default motion — the suite's long-standing flake.
  const mount = (): EditorView => mdView(DOC, { clearBody: false, ensureTree: true });

  it('Shift+ArrowUp from the line below a table lands just above the table (one step)', () => {
    const view = mount();
    // Cursor on line 7 (blank line directly below table A end at line 6).
    const line7 = view.state.doc.line(7);
    view.dispatch({ selection: EditorSelection.cursor(line7.from) });

    press(view, 'ArrowUp', true);

    // Should extend to line 3 (the blank line directly above table A start, line 4),
    // NOT skip further up to line 2/1.
    const head = view.state.selection.main.head;
    const headLine = view.state.doc.lineAt(head).number;
    expect(headLine).toBe(3);
    // anchor preserved (selection extended, not collapsed)
    expect(view.state.selection.main.anchor).toBe(line7.from);
    view.destroy();
  });

  it('ArrowDown from the line above a table lands just below the table (one step)', () => {
    const view = mount();
    // Cursor on line 3 (blank line directly above table A start at line 4).
    const line3 = view.state.doc.line(3);
    view.dispatch({ selection: EditorSelection.cursor(line3.from) });

    press(view, 'ArrowDown', false);

    const head = view.state.selection.main.head;
    const headLine = view.state.doc.lineAt(head).number;
    expect(headLine).toBe(7); // blank line below table A end (line 6)
    view.destroy();
  });

  it('does not intercept ordinary vertical motion away from tables', () => {
    const view = mount();
    // Cursor on line 2 (beta); line above (1, alpha) is not a table.
    const line2 = view.state.doc.line(2);
    view.dispatch({ selection: EditorSelection.cursor(line2.from) });
    press(view, 'ArrowUp', false);
    // The table keymap must return false here; default motion handles it.
    // We only assert it did NOT jump anywhere table-related (head <= line 2 start area).
    const headLine = view.state.doc.lineAt(view.state.selection.main.head).number;
    expect(headLine).toBeLessThanOrEqual(2);
    view.destroy();
  });
});

describe('tableBetween', () => {
  // Line map: DOC above, table A on lines 4-6.
  it('finds only a table strictly between the two lines', () => {
    const view = mdView(DOC, { ensureTree: true });
    const { tableBetween } = _testing;
    expect(tableBetween(view.state, 2, 8)).toBe(true);
    expect(tableBetween(view.state, 3, 7)).toBe(true);
    expect(tableBetween(view.state, 4, 8)).toBe(false); // starts on the bound
    expect(tableBetween(view.state, 2, 6)).toBe(false); // ends on the bound
    expect(tableBetween(view.state, 1, 3)).toBe(false);
    view.destroy();
  });

  it('finds a table nested in a blockquote', () => {
    const view = mdView('top\n\n> | a | b |\n> | - | - |\n> | 1 | 2 |\n\nend', { ensureTree: true });
    expect(_testing.tableBetween(view.state, 1, 7)).toBe(true);
    view.destroy();
  });
});
