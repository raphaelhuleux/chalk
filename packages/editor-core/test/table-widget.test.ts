import { describe, it, expect, beforeEach } from 'vitest';
import type { EditorView } from '@codemirror/view';
import { createEditor } from '../src/editor/setup';
import { parsed } from './helpers/force-parse';
import { TableWidget } from '../src/editor/table-widget';
import { parseTable, serializeTable } from '../src/editor/table-model';

// toDOM only touches `view` inside event-listener closures (never during the
// initial build), so a stub is safe for render-only assertions.
const stubView = {} as unknown as EditorView;

describe('TableWidget rendering', () => {
  it('renders header and body cells with unescaped text', () => {
    const w = new TableWidget(parseTable('| a \\| b | c |\n| - | - |\n| 1 | 2 |'));
    const dom = w.toDOM(stubView);
    const ths = Array.from(dom.querySelectorAll('thead th')).map((th) => th.textContent);
    const tds = Array.from(dom.querySelectorAll('tbody td')).map((td) => td.textContent);
    expect(ths).toEqual(['a | b', 'c']); // \| revealed as |
    expect(tds).toEqual(['1', '2']);
  });

  it('applies alignment classes from the delimiter row', () => {
    const w = new TableWidget(parseTable('| a | b | c |\n| :- | :-: | -: |\n| 1 | 2 | 3 |'));
    const dom = w.toDOM(stubView);
    const ths = dom.querySelectorAll('thead th');
    expect(ths[0].className).toContain('left');
    expect(ths[1].className).toContain('center');
    expect(ths[2].className).toContain('right');
  });

  it('round-trips DOM edits back through domToModel with escaping', () => {
    const w = new TableWidget(parseTable('| a | b |\n| - | - |\n| 1 | 2 |'));
    const dom = w.toDOM(stubView);
    const table = dom.querySelector('table') as HTMLTableElement;
    // Simulate the user typing a pipe into the first body cell.
    (table.querySelector('tbody td') as HTMLElement).textContent = 'x | y';
    const model = w.domToModel(table);
    expect(model.rows[0][0]).toBe('x \\| y'); // re-escaped on read
    expect(serializeTable(model)).toContain('x \\| y');
  });
});

describe('table rendering in a mounted md editor', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  it('replaces pipe source with a <table> widget', () => {
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const view = parsed(createEditor(
      parent,
      'before\n\n| Name | Score |\n| :--- | ----: |\n| Ann | 92 |\n\nafter',
      { onContentChange: () => {} },
      'md',
    ));
    const table = view.dom.querySelector('table.cm-live-table');
    expect(table).not.toBeNull();
    expect(table!.querySelectorAll('thead th').length).toBe(2);
    expect(table!.querySelectorAll('tbody tr').length).toBe(1);
    view.destroy();
    parent.remove();
  });

  // M-15: Tab/Enter/Escape must never be hijacked mid-IME-composition — the
  // key event that confirms a composition (isComposing / keyCode 229) would
  // otherwise move focus or grow the table under the composing user.
  it('does not steal Enter/Tab during IME composition', () => {
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const view = parsed(createEditor(
      parent,
      '| a | b |\n| --- | --- |\n| 1 | 2 |',
      { onContentChange: () => {} },
      'md',
    ));
    const th = view.dom.querySelector<HTMLElement>('thead th')!;
    th.focus();
    expect(document.activeElement).toBe(th);
    const rowsBefore = view.dom.querySelectorAll('tbody tr').length;

    const composingEnter = new KeyboardEvent('keydown', {
      key: 'Enter',
      isComposing: true,
      bubbles: true,
      cancelable: true,
    });
    th.dispatchEvent(composingEnter);
    // Not hijacked: no preventDefault, focus stays, no structural change.
    expect(composingEnter.defaultPrevented).toBe(false);
    expect(document.activeElement).toBe(th);
    expect(view.dom.querySelectorAll('tbody tr').length).toBe(rowsBefore);

    const composingTab = new KeyboardEvent('keydown', {
      key: 'Tab',
      isComposing: true,
      bubbles: true,
      cancelable: true,
    });
    th.dispatchEvent(composingTab);
    expect(composingTab.defaultPrevented).toBe(false);
    expect(document.activeElement).toBe(th);

    // Control: the same Enter OUTSIDE composition is handled (preventDefault).
    const plainEnter = new KeyboardEvent('keydown', {
      key: 'Enter',
      bubbles: true,
      cancelable: true,
    });
    th.dispatchEvent(plainEnter);
    expect(plainEnter.defaultPrevented).toBe(true);

    view.destroy();
    parent.remove();
  });
});

describe('select-all containment in cells', () => {
  it('Cmd+A inside a cell selects the cell, not the document', () => {
    document.body.innerHTML = '';
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const view = parsed(createEditor(
      parent,
      'before\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\nafter',
      { onContentChange: () => {} },
      'md',
    ));
    const cell = view.dom.querySelector('tbody td') as HTMLElement;
    cell.focus();
    const before = view.state.doc.toString();
    cell.dispatchEvent(
      new KeyboardEvent('keydown', {
        key: 'a',
        metaKey: true,
        bubbles: true,
        cancelable: true,
      }),
    );
    // CM6 select-all must not have taken over: typing replaces at most the
    // cell selection, and the editor selection stays collapsed/unchanged.
    expect(view.state.selection.main.from).toBe(view.state.selection.main.to);
    expect(view.state.doc.toString()).toBe(before);
    const domSel = window.getSelection();
    expect(domSel && cell.contains(domSel.anchorNode)).toBe(true);
    view.destroy();
  });
});
