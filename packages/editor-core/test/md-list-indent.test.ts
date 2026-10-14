import { describe, it, expect, afterEach } from 'vitest';
import { EditorSelection } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { mdView, destroyViews } from './helpers/views';

/**
 * Integration tests for Tab / Shift+Tab on an ordered Markdown list item.
 *
 * These mount a real md editor and dispatch actual Tab keydowns so the whole
 * keymap chain runs — verifying mdListIndentKeymap wins over the generic
 * `indentWithTab` (which indents the line and leaves the number alone) while
 * still losing to hsnips / completion / Tabout where those apply.
 */
function press(view: EditorView, shift = false): string {
  view.contentDOM.dispatchEvent(
    new KeyboardEvent('keydown', {
      key: 'Tab',
      code: 'Tab',
      shiftKey: shift,
      bubbles: true,
      cancelable: true,
    }),
  );
  return view.state.doc.toString();
}

/** Park the caret at `col` on `line` (1-based), defaulting to the line end. */
function caret(view: EditorView, line: number, col?: number): void {
  const ln = view.state.doc.line(line);
  view.dispatch({ selection: EditorSelection.cursor(col == null ? ln.to : ln.from + col) });
}

afterEach(() => destroyViews());

describe('Tab on an ordered list item', () => {
  it('nests the item and restarts its number at 1', () => {
    const view = mdView('1. a\n2. ');
    caret(view, 2);
    expect(press(view)).toBe('1. a\n    1. ');
  });

  it('renumbers the following siblings at the old indent', () => {
    const view = mdView('1. a\n2. b\n3. c');
    caret(view, 2);
    expect(press(view)).toBe('1. a\n    1. b\n2. c');
  });

  it('nests twice, restarting at 1 each time', () => {
    const view = mdView('1. a\n2. b');
    caret(view, 2);
    expect(press(view)).toBe('1. a\n    1. b');
    expect(press(view)).toBe('1. a\n        1. b');
  });

  it('numbers after the nearest preceding sibling at the new indent', () => {
    const view = mdView('1. a\n    1. x\n2. b');
    caret(view, 3);
    expect(press(view)).toBe('1. a\n    1. x\n    2. b');
  });

  it('preserves the `)` delimiter', () => {
    const view = mdView('1) a\n2) b');
    caret(view, 2);
    expect(press(view)).toBe('1) a\n    1) b');
  });

  it('keeps the caret on the same character of the body', () => {
    const view = mdView('1. a\n2. bcd');
    caret(view, 2, 5); // between "b" and "c"
    press(view);
    const ln = view.state.doc.line(2);
    expect(view.state.doc.toString()).toBe('1. a\n    1. bcd');
    expect(view.state.selection.main.head - ln.from).toBe(9); // "    1. b|cd"
  });

  it('leaves a bullet line to the plain indent command', () => {
    const view = mdView('- a\n- b');
    caret(view, 2);
    expect(press(view)).toBe('- a\n    - b');
  });

  it('falls through on a non-empty selection', () => {
    const view = mdView('1. a\n2. b');
    const ln = view.state.doc.line(2);
    view.dispatch({ selection: EditorSelection.range(ln.from, ln.to) });
    expect(press(view)).toBe('1. a\n    2. b'); // plain indent, number untouched
  });

  it('falls through inside inline math on a list line', () => {
    const view = mdView('1. a\n2. $x+1$ tail');
    caret(view, 2, 5); // inside $x+1$
    expect(press(view)).toBe('1. a\n2. $x+1$ tail');
  });
});

describe('Shift+Tab on an ordered list item', () => {
  it('dedents and renumbers both levels', () => {
    const view = mdView('1. a\n    1. b\n2. c');
    caret(view, 2);
    expect(press(view, true)).toBe('1. a\n2. b\n3. c');
  });

  it('is a no-op at the outermost indent', () => {
    const view = mdView('1. a\n2. b');
    caret(view, 2);
    expect(press(view, true)).toBe('1. a\n2. b');
  });
});
