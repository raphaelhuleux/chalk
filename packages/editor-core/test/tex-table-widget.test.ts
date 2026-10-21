import { describe, it, expect, afterEach } from 'vitest';
import type { EditorView } from '@codemirror/view';
import { texView } from './helpers/views';
import { texTableField } from '../src/editor/tex-table-field';
import { applyViewMode } from '../src/editor/view-mode';

const TABLE = String.raw`Before.

\begin{center}
\resizebox{\textwidth}{!}{
\begin{tabular}{lcc}
\toprule
 & $\zeta_{c}$ & Top 1\%\\
\midrule
Data & 3.06 & 35\%\\
Model & \textbf{2.65} & 29\%\\
\bottomrule
\end{tabular}}
\end{center}

After.`;

/** Let rAF-deferred flushes and refocuses run. */
async function settle(): Promise<void> {
  await new Promise((r) => setTimeout(r, 40));
}

function cell(view: EditorView, row: number, k: number): HTMLElement {
  return view.dom.querySelector<HTMLElement>(`td[data-row="${row}"][data-cell="${k}"]`)!;
}

function key(el: HTMLElement, k: string, opts: KeyboardEventInit = {}): KeyboardEvent {
  const e = new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true, ...opts });
  el.dispatchEvent(e);
  return e;
}

function button(view: EditorView, title: string): HTMLElement {
  return view.dom.querySelector<HTMLElement>(`.cm-tex-table-wrap button[title^="${title}"]`)!;
}

function press(el: HTMLElement): void {
  el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
}

let view: EditorView;
afterEach(() => view?.destroy());

describe('tex table widget', () => {
  it('renders a tabular as a table with rules, math and text macros', () => {
    view = texView(TABLE);
    const table = view.dom.querySelector('table.cm-tex-table');
    expect(table).not.toBeNull();
    expect(table!.querySelectorAll('tr')).toHaveLength(3);
    expect(cell(view, 0, 1).querySelector('.katex')).not.toBeNull();
    expect(cell(view, 0, 2).textContent).toBe('Top 1%');
    expect(cell(view, 2, 1).querySelector('b')?.textContent).toBe('2.65');
    expect(cell(view, 0, 0).className).toContain('cm-tex-rule-top-heavy');
    expect(cell(view, 1, 0).className).toContain('cm-tex-rule-top-thin');
    expect(cell(view, 2, 0).className).toContain('cm-tex-rule-bottom-heavy');
    expect(cell(view, 1, 1).className).toContain('center');
    // The `\resizebox{…}{` line stays source; the `}` sharing the end line
    // shows as a dim strip.
    expect(view.dom.textContent).toContain('\\resizebox{\\textwidth}{!}{');
    expect(view.dom.querySelector('.cm-tex-table-src')?.textContent).toBe('}');
  });

  it('a focused cell shows its source; a flush rewrites only that cell', async () => {
    view = texView(TABLE);
    const td = cell(view, 1, 2);
    td.focus();
    expect(td.getAttribute('contenteditable')).toBe('true');
    expect(td.textContent).toBe('35\\%');
    td.textContent = '36%';
    td.blur();
    await settle();
    // Typed `%` is escaped so it can't comment out the row.
    expect(view.state.doc.toString()).toBe(TABLE.replace('35\\%', '36\\%'));
  });

  it('Escape flushes and puts the caret after the table', () => {
    view = texView(TABLE);
    const td = cell(view, 2, 0);
    td.focus();
    td.textContent = 'Model B';
    key(td, 'Escape');
    const doc = view.state.doc.toString();
    expect(doc).toContain('Model B & \\textbf{2.65}');
    expect(view.state.selection.main.head).toBe(doc.indexOf('\\end{tabular}}') + '\\end{tabular}}'.length);
  });

  it('an untouched focus round-trip writes nothing', async () => {
    view = texView(TABLE);
    const td = cell(view, 0, 1);
    td.focus();
    td.blur();
    await settle();
    expect(view.state.doc.toString()).toBe(TABLE);
  });

  it('a cell rewritten underneath keeps the rewrite', async () => {
    view = texView(TABLE);
    const td = cell(view, 1, 1);
    td.focus();
    td.textContent = '9.99';
    // A host write to the same cell lands before the flush.
    const at = view.state.doc.toString().indexOf('3.06');
    view.dispatch({ changes: { from: at, to: at + 4, insert: '3.07' } });
    await settle();
    expect(view.state.doc.toString()).toContain('Data & 3.07');
    expect(view.state.doc.toString()).not.toContain('9.99');
  });

  it('Tab past the last cell appends a row', async () => {
    view = texView(TABLE);
    const td = cell(view, 2, 2);
    td.focus();
    key(td, 'Tab');
    await settle();
    expect(view.state.doc.toString()).toContain('29\\%\\\\\n& & \\\\\n\\bottomrule');
  });

  it('toolbar ops edit the spec and rows as one transaction', async () => {
    view = texView(TABLE);
    cell(view, 1, 1).focus();
    press(button(view, 'Insert column right'));
    await settle();
    const doc = view.state.doc.toString();
    expect(doc).toContain('{lccc}');
    expect(doc).toContain('Data & 3.06 & & 35\\%');
    // Focus followed the new column, so alignment applies to it.
    press(button(view, 'Align column right'));
    expect(view.state.doc.toString()).toContain('{lcrc}');
  });

  it('{ } reveals the source until the caret leaves the table', () => {
    view = texView(TABLE);
    cell(view, 0, 0).focus();
    press(button(view, 'Edit table source'));
    expect(view.dom.querySelector('table.cm-tex-table')).toBeNull();
    expect(view.state.field(texTableField).revealed).not.toBeNull();
    view.dispatch({ selection: { anchor: 0 } });
    expect(view.dom.querySelector('table.cm-tex-table')).not.toBeNull();
  });

  it('renders in Mixed, not in Source', () => {
    view = texView(TABLE, { viewMode: 'mixed' });
    expect(view.dom.querySelector('table.cm-tex-table')).not.toBeNull();
    applyViewMode(view, 'source');
    expect(view.dom.querySelector('table.cm-tex-table')).toBeNull();
  });

  it('leaves a malformed or in-math tabular as source', () => {
    view = texView('\\begin{tabular}{l}\n\\textbf{a \\\\\n\\end{tabular}\n\n$\\begin{tabular}{l} x \\end{tabular}$');
    expect(view.dom.querySelector('table.cm-tex-table')).toBeNull();
  });
});
