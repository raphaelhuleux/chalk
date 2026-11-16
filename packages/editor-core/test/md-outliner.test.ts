import { describe, it, expect, afterEach } from 'vitest';
import { EditorSelection } from '@codemirror/state';
import { foldedRanges, foldEffect, unfoldCode } from '@codemirror/language';
import type { EditorView } from '@codemirror/view';
import { mdView, destroyViews } from './helpers/views';
import {
  foldAtCaret,
  foldRangeAtLine,
  foldToLevel,
  toggleFoldAtLine,
} from '../src/editor/md-fold';

/**
 * The Markdown outliner keys, through real keydowns on a mounted md editor so
 * the whole keymap chain runs. jsdom is not a Mac, so Mod is Ctrl. Policy
 * table: docs/specs/2026-11-07-markdown-outliner.md.
 */

afterEach(() => destroyViews());

interface Mods {
  shift?: boolean;
  alt?: boolean;
  mod?: boolean;
  keyCode?: number;
}

function press(view: EditorView, key: string, m: Mods = {}): string {
  view.contentDOM.dispatchEvent(
    new KeyboardEvent('keydown', {
      key,
      keyCode: m.keyCode,
      shiftKey: !!m.shift,
      altKey: !!m.alt,
      ctrlKey: !!m.mod,
      bubbles: true,
      cancelable: true,
    }),
  );
  return view.state.doc.toString();
}

function caret(view: EditorView, line: number, col?: number): void {
  const ln = view.state.doc.line(line);
  view.dispatch({ selection: EditorSelection.cursor(col == null ? ln.to : ln.from + col) });
}

function folds(view: EditorView): string[] {
  const out: string[] = [];
  const { doc } = view.state;
  foldedRanges(view.state).between(0, doc.length, (from, to) => {
    out.push(`${doc.lineAt(from).number}-${doc.lineAt(to).number}`);
  });
  return out;
}

describe('folding', () => {
  const doc = '# A\ntext\n- a\n    - a1\n    - a2\n- b\n\n# B\nb';

  it('folds a list subtree behind its head line', () => {
    const view = mdView(doc);
    caret(view, 4);
    expect(foldAtCaret(view)).toBe(true); // a1 is a leaf: its parent folds
    expect(folds(view)).toEqual(['3-5']);
  });

  it('folding again from inside folds the parent; the caret leaves hidden text', () => {
    const view = mdView(doc);
    caret(view, 5);
    foldAtCaret(view);
    expect(folds(view)).toEqual(['3-5']);
    foldAtCaret(view);
    expect(folds(view)).toEqual(['1-6', '3-5']);
    expect(view.state.selection.main.head).toBe(view.state.doc.line(1).to);
  });

  it('a heading section stops before the next same-level heading', () => {
    const view = mdView(doc);
    expect(foldRangeAtLine(view.state, 1)).toEqual({
      from: view.state.doc.line(1).to,
      to: view.state.doc.line(6).to,
    });
  });

  it('toggles from the chevron and unfolds from the head row', () => {
    const view = mdView(doc);
    toggleFoldAtLine(view, 8);
    expect(folds(view)).toEqual(['8-9']);
    caret(view, 8);
    expect(unfoldCode(view)).toBe(true);
    expect(folds(view)).toEqual([]);
  });

  it('fold to level 1 folds top headings; level 0 unfolds all', () => {
    const view = mdView(doc);
    foldToLevel(view, 1);
    expect(folds(view)).toEqual(['1-6', '8-9']);
    foldToLevel(view, 0);
    expect(folds(view)).toEqual([]);
  });

  it('Backspace or Delete that would eat a fold unfolds it and deletes nothing', () => {
    const view = mdView(doc);
    toggleFoldAtLine(view, 3);
    caret(view, 6, 0);
    expect(press(view, 'Backspace')).toBe(doc);
    expect(folds(view)).toEqual([]);
    toggleFoldAtLine(view, 3);
    caret(view, 3);
    expect(press(view, 'Delete')).toBe(doc);
    expect(folds(view)).toEqual([]);
  });

  it('typing at the far edge of a fold shows the line it lands on', () => {
    const view = mdView(doc);
    toggleFoldAtLine(view, 3);
    const end = view.state.doc.line(5).to;
    view.dispatch({ changes: { from: end, insert: 'x' }, userEvent: 'input.type' });
    expect(folds(view)).toEqual([]);
  });

  it('Backspace at the head row end edits the head line', () => {
    const view = mdView(doc);
    toggleFoldAtLine(view, 3);
    caret(view, 3);
    expect(press(view, 'Backspace')).toBe(doc.replace('- a\n', '- \n'));
    expect(folds(view)).toEqual(['3-5']);
  });

  it('a search hit or outline jump inside a fold unfolds it', () => {
    const view = mdView(doc);
    toggleFoldAtLine(view, 3);
    caret(view, 4, 6);
    expect(folds(view)).toEqual([]);
  });

  it('Enter at the end of a folded item opens a sibling after the children', () => {
    const view = mdView('1. a\n    - a1\n2. b');
    toggleFoldAtLine(view, 1);
    caret(view, 1);
    expect(press(view, 'Enter')).toBe('1. a\n    - a1\n2. \n3. b');
    expect(folds(view)).toEqual(['1-2']);
  });
});

describe('Tab on a bullet carries its subtree', () => {
  it('indents children with the item', () => {
    const view = mdView('- a\n- b\n    - b1\n- c');
    caret(view, 2);
    expect(press(view, 'Tab')).toBe('- a\n    - b\n        - b1\n- c');
  });

  it('outdents children with the item', () => {
    const view = mdView('- a\n    - b\n        - b1\n    - c');
    caret(view, 2);
    expect(press(view, 'Tab', { shift: true })).toBe('- a\n- b\n    - b1\n    - c');
  });

  it('an ordered item with children renumbers only real siblings', () => {
    const view = mdView('1. a\n2. b\n    1. x\n3. c');
    caret(view, 2);
    expect(press(view, 'Tab')).toBe('1. a\n    1. b\n        1. x\n2. c');
  });

  it('keeps a folded subtree folded as it moves', () => {
    const view = mdView('- a\n- b\n    - b1\n- c');
    toggleFoldAtLine(view, 2);
    caret(view, 2);
    press(view, 'Tab');
    expect(folds(view)).toEqual(['2-3']);
    press(view, 'Tab', { shift: true });
    expect(folds(view)).toEqual(['2-3']);
  });
});

describe('Tab on a heading', () => {
  it('demotes the heading and its subheadings', () => {
    const view = mdView('# A\n## A1\ntext\n# B');
    caret(view, 1);
    expect(press(view, 'Tab')).toBe('## A\n### A1\ntext\n# B');
    expect(press(view, 'Tab', { shift: true })).toBe('# A\n## A1\ntext\n# B');
  });

  it('refuses to promote past level 1', () => {
    const view = mdView('# A\ntext');
    caret(view, 1);
    expect(press(view, 'Tab', { shift: true })).toBe('# A\ntext');
  });
});

describe('Alt-Up / Alt-Down move a subtree', () => {
  it('swaps an item and its children with the next sibling', () => {
    const view = mdView('- a\n    - a1\n- b\n- c');
    caret(view, 1, 3);
    expect(press(view, 'ArrowDown', { alt: true })).toBe('- b\n- a\n    - a1\n- c');
    expect(view.state.doc.lineAt(view.state.selection.main.head).number).toBe(2);
  });

  it('swaps heading sections and keeps the blank lines between them', () => {
    const view = mdView('# A\na\n\n# B\nb\n\n# C');
    caret(view, 4);
    expect(press(view, 'ArrowUp', { alt: true })).toBe('# B\nb\n\n# A\na\n\n# C');
  });

  it('keeps ordered numbers in place', () => {
    const view = mdView('1. a\n2. b\n3. c');
    caret(view, 3);
    expect(press(view, 'ArrowUp', { alt: true })).toBe('1. a\n2. c\n3. b');
  });

  it('does nothing at the first sibling instead of leaving the parent', () => {
    const view = mdView('- p\n    - a\n    - b');
    caret(view, 2);
    expect(press(view, 'ArrowUp', { alt: true })).toBe('- p\n    - a\n    - b');
  });

  it('moves folds with their text', () => {
    const view = mdView('- a\n    - a1\n- b\n    - b1');
    toggleFoldAtLine(view, 1);
    caret(view, 3);
    press(view, 'ArrowUp', { alt: true });
    expect(view.state.doc.toString()).toBe('- b\n    - b1\n- a\n    - a1');
    expect(folds(view)).toEqual(['3-4']);
  });

  it('falls through to the stock line move on plain text', () => {
    const view = mdView('one\ntwo');
    caret(view, 2);
    expect(press(view, 'ArrowUp', { alt: true })).toBe('two\none');
  });

  it('a fold effect on a moved region is not duplicated', () => {
    const view = mdView('- a\n    - a1\n- b');
    view.dispatch({ effects: foldEffect.of(foldRangeAtLine(view.state, 1)!) });
    caret(view, 1);
    press(view, 'ArrowDown', { alt: true });
    expect(folds(view)).toEqual(['2-3']);
  });
});

describe('Backspace at an item body start peels one layer', () => {
  it('outdents a nested item first', () => {
    const view = mdView('- a\n    - b');
    caret(view, 2);
    expect(press(view, 'Backspace')).toBe('- a\n    - ');
    caret(view, 2, 6);
    expect(press(view, 'Backspace')).toBe('- a\n- ');
  });

  it('removes a task box, then the marker', () => {
    const view = mdView('- [ ] t');
    caret(view, 1, 6);
    expect(press(view, 'Backspace')).toBe('- t');
    expect(press(view, 'Backspace')).toBe('t');
  });

  it('closes the gap in an ordered run', () => {
    const view = mdView('1. a\n2. b\n3. c');
    caret(view, 1, 3);
    expect(press(view, 'Backspace')).toBe('a\n1. b\n2. c');
  });

  it('leaves a Backspace inside the body alone', () => {
    const view = mdView('- ab');
    caret(view, 1);
    expect(press(view, 'Backspace')).toBe('- a');
  });
});

describe('Mod-Enter steps a checkbox', () => {
  it('adds a box, ticks it, unticks it', () => {
    const view = mdView('- a');
    caret(view, 1);
    expect(press(view, 'Enter', { mod: true })).toBe('- [ ] a');
    expect(press(view, 'Enter', { mod: true })).toBe('- [x] a');
    expect(press(view, 'Enter', { mod: true })).toBe('- [ ] a');
  });

  it('falls through on plain text', () => {
    const view = mdView('plain');
    caret(view, 1);
    expect(press(view, 'Enter', { mod: true })).not.toContain('[ ]');
  });
});

describe('Mod-Shift-7 / 8 / 9 set the list type', () => {
  const key = (n: number) => ({ mod: true, shift: true, keyCode: 48 + n });

  it('makes bullets, then plain lines again', () => {
    const view = mdView('a\nb');
    view.dispatch({ selection: EditorSelection.range(0, 3) });
    expect(press(view, '*', key(8))).toBe('- a\n- b');
    view.dispatch({ selection: EditorSelection.range(0, view.state.doc.length) });
    expect(press(view, '*', key(8))).toBe('a\nb');
  });

  it('numbers per indent level', () => {
    const view = mdView('- a\n    - x\n    - y\n- b');
    view.dispatch({ selection: EditorSelection.range(0, view.state.doc.length) });
    expect(press(view, '&', key(7))).toBe('1. a\n    1. x\n    2. y\n2. b');
  });

  it('turns a heading into a task', () => {
    const view = mdView('## Todo');
    caret(view, 1);
    expect(press(view, '(', key(9))).toBe('- [ ] Todo');
  });
});

describe('zoom', () => {
  const doc = '# A\na\n# B\n- b1\n    - b2\n# C\nc';

  async function zoomed(line: number) {
    const { zoomIn, zoomField } = await import('../src/editor/md-zoom');
    const view = mdView(doc);
    caret(view, line);
    expect(zoomIn(view)).toBe(true);
    return { view, zoomField };
  }

  it('zooms into the innermost node and hides the rest', async () => {
    const { view, zoomField } = await zoomed(5);
    const z = view.state.field(zoomField)!;
    expect(view.state.doc.lineAt(z.from).number).toBe(4);
    expect(view.state.doc.lineAt(z.to).number).toBe(5);
    expect(view.dom.querySelector('.cm-md-zoom-bar')?.textContent).toBe('Document›B›b1');
  });

  it('keyboard motion is clamped, other jumps end the zoom', async () => {
    const { view, zoomField } = await zoomed(3);
    view.dispatch({ selection: EditorSelection.cursor(0), userEvent: 'select' });
    expect(view.state.field(zoomField)).not.toBeNull();
    expect(view.state.selection.main.head).toBe(view.state.doc.line(3).from);
    view.dispatch({ selection: EditorSelection.cursor(0), userEvent: 'select.search' });
    expect(view.state.field(zoomField)).toBeNull();
  });

  it('Escape zooms out', async () => {
    const { view, zoomField } = await zoomed(1);
    press(view, 'Escape');
    expect(view.state.field(zoomField)).toBeNull();
  });
});
