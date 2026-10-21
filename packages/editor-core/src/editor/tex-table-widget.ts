// TexTableWidget: in-place editing of a LaTeX tabular. Like the GFM widget
// (table-widget.ts) the wrap is a non-editable block-replace widget and edits
// buffer in the DOM, flushing on blur, Escape or a structural op. Unlike it,
// a cell shows its rendered tex until focused and its raw source while
// focused, and a flush writes ONLY the cells that changed (tex-table-model.ts
// edits ranges, it never re-serializes the table).
//
// Positions are never stored: every write re-scans the live document and
// writes a cell only if its source still equals what this DOM was built
// from, so a host update that rewrote the table can't receive a stale edit.

import { EditorView, WidgetType } from '@codemirror/view';
import { ChangeSet, EditorSelection, StateEffect, type Text } from '@codemirror/state';
import type { KaTeXCache } from '../utils/katex-cache';
import { docText } from '../utils/doc-text';
import { calloutTagClasses, sameCalloutTag, type CalloutTag } from './callout-core';
import { renderTexCell } from './tex-cell-render';
import {
  type TexAlign,
  type TexChange,
  type TexRule,
  type TexTable,
  canSetAlign,
  cellEdit,
  deleteColumnEdit,
  deleteRowEdit,
  insertColumnEdit,
  insertRowEdit,
  setAlignEdit,
  tableAt,
  texTablesOf,
  toggleRuleBelowEdit,
} from './tex-table-model';
import '../styles/table.css';

/** Show one table's source until the caret leaves it (the toolbar's `{}`). */
export const revealTexTable = StateEffect.define<{ from: number; to: number } | null>({
  map: (v, m) => (v ? { from: m.mapPos(v.from, -1), to: m.mapPos(v.to, 1) } : null),
});

interface CellEditRecord {
  row: number;
  cell: number;
  original: string;
  text: string;
}

const viewForWrap = new WeakMap<HTMLElement, EditorView>();
/** Current source text of each cell's DOM, edited or not. */
const cellText = new WeakMap<HTMLElement, string>();
/** Wraps whose buffer was already written: a teardown must not replay it. */
const committed = new WeakSet<HTMLElement>();

const ALIGN_CLASS: Record<TexAlign, string> = {
  left: 'cm-live-table-cell--left',
  center: 'cm-live-table-cell--center',
  right: 'cm-live-table-cell--right',
};

function placeCaretEnd(el: HTMLElement): void {
  el.focus();
  const range = document.createRange();
  range.selectNodeContents(el);
  range.collapse(false);
  const sel = window.getSelection();
  sel?.removeAllRanges();
  sel?.addRange(range);
}

/** `thin` / `heavy` / `double` for the rules touching logical cols `c0..c1`. */
function ruleClass(rules: readonly TexRule[], c0: number, c1: number): string | null {
  const hit = rules.filter((r) => r.from <= c1 && r.to >= c0);
  if (hit.length === 0) return null;
  if (hit.length > 1) return 'double';
  return hit[0].weight;
}

function lineStartOf(doc: Text, pos: number): number {
  return doc.lineAt(pos).from;
}

export class TexTableWidget extends WidgetType {
  private focused = { row: 0, cell: 0 };
  /** Cell source at build time, `[row][cell]`. */
  private readonly raws: string[][];

  constructor(
    readonly table: TexTable,
    /** The environment's source: render-equality and the flush guard. */
    readonly source: string,
    /** Text sharing the `\begin` / `\end` lines (a `\resizebox{…}{` or its
     *  closing `}`), shown dimmed above and below since the replace hides
     *  those whole lines. */
    readonly prefix: string,
    readonly suffix: string,
    readonly cache: KaTeXCache,
    readonly callout: CalloutTag | null = null,
    readonly frame: boolean = false,
  ) {
    super();
    const base = table.from;
    this.raws = table.rows.map((r) =>
      r.cells.map((c) => source.slice(c.editFrom - base, c.editTo - base)),
    );
  }

  eq(other: TexTableWidget): boolean {
    // Render-equality, so edits elsewhere reuse the DOM and keep a focused
    // cell's caret.
    return (
      this.source === other.source &&
      this.prefix === other.prefix &&
      this.suffix === other.suffix &&
      this.frame === other.frame &&
      sameCalloutTag(this.callout, other.callout)
    );
  }

  ignoreEvent(): boolean {
    return true;
  }

  // ---- Live lookup ----

  /** The live table this DOM renders: the one whose `\begin` line starts at
   *  the widget's position. */
  private locate(view: EditorView, wrap: HTMLElement): TexTable | null {
    const pos = this.lineFromOf(view, wrap);
    return pos === null ? null : this.tableFromLine(view.state.doc, pos);
  }

  /** The widget's start (its `\begin` line), or null once detached. A flush
   *  only changes text after it, so it stays valid across one. */
  private lineFromOf(view: EditorView, wrap: HTMLElement): number | null {
    try {
      return view.posAtDOM(wrap);
    } catch {
      return null;
    }
  }

  private tableFromLine(doc: Text, lineFrom: number): TexTable | null {
    const tables = texTablesOf(doc);
    return (
      tables.find((t) => lineStartOf(doc, t.from) === lineFrom) ?? tableAt(tables, lineFrom)
    );
  }

  private sameShape(t: TexTable): boolean {
    return (
      t.rows.length === this.table.rows.length &&
      t.rows.every((r, i) => r.cells.length === this.table.rows[i].cells.length)
    );
  }

  // ---- Buffer ----

  private cells(wrap: HTMLElement): HTMLElement[] {
    return Array.from(wrap.querySelectorAll<HTMLElement>('td[data-cell]'));
  }

  private currentText(td: HTMLElement): string {
    if (td.classList.contains('cm-tex-cell-editing')) return td.textContent ?? '';
    return cellText.get(td) ?? '';
  }

  private collectEdits(wrap: HTMLElement): CellEditRecord[] {
    const edits: CellEditRecord[] = [];
    for (const td of this.cells(wrap)) {
      const row = Number(td.dataset.row);
      const cell = Number(td.dataset.cell);
      const original = this.raws[row]?.[cell];
      if (original === undefined) continue;
      const text = this.currentText(td);
      if (text.trim() !== original.trim()) edits.push({ row, cell, original, text });
    }
    return edits;
  }

  /** Changes writing `edits` into `live`, skipping any cell whose source no
   *  longer matches the one the edit was typed over. */
  private mapEdits(text: string, live: TexTable, edits: CellEditRecord[]): TexChange[] {
    const out: TexChange[] = [];
    for (const e of edits) {
      const cell = live.rows[e.row]?.cells[e.cell];
      if (!cell || text.slice(cell.editFrom, cell.editTo) !== e.original) continue;
      const change = cellEdit(text, cell, e.text);
      if (change) out.push(change);
    }
    return out;
  }

  // ---- Flush ----

  private flush(view: EditorView, wrap: HTMLElement): void {
    if (committed.has(wrap)) return;
    const edits = this.collectEdits(wrap);
    if (edits.length === 0) return;
    const live = this.locate(view, wrap);
    if (!live || !this.sameShape(live)) return;
    const changes = this.mapEdits(docText(view.state.doc), live, edits);
    if (changes.length === 0) return;
    committed.add(wrap);
    view.dispatch({ changes, userEvent: 'table.edit' });
  }

  /**
   * Last-chance write when the DOM is discarded with buffered edits (a host
   * update rewrote this table while a cell was focused). The position is read
   * while the DOM is still linked; the dispatch waits a microtask, since
   * widget teardown runs inside a CM6 update. Per-cell source matching makes
   * a stale range harmless: a cell that changed underneath keeps the update.
   */
  private rescue(view: EditorView, wrap: HTMLElement): void {
    if (committed.has(wrap)) return;
    const edits = this.collectEdits(wrap);
    if (edits.length === 0) return;
    let pos: number;
    try {
      pos = view.posAtDOM(wrap);
    } catch {
      return;
    }
    committed.add(wrap);
    queueMicrotask(() => {
      if (view.dom.contains(wrap)) {
        committed.delete(wrap); // DOM survived: the normal flush owns it
        return;
      }
      try {
        const doc = view.state.doc;
        if (pos > doc.length) return;
        const live = this.tableFromLine(doc, lineStartOf(doc, pos));
        if (!live || !this.sameShape(live)) return;
        const changes = this.mapEdits(docText(doc), live, edits);
        if (changes.length) view.dispatch({ changes, userEvent: 'table.edit' });
      } catch {
        // View destroyed: drop.
      }
    });
  }

  destroy(dom: HTMLElement): void {
    const view = viewForWrap.get(dom);
    if (view) this.rescue(view, dom);
  }

  updateDOM(dom: HTMLElement, view: EditorView, from: TexTableWidget): boolean {
    from.rescue(view, dom);
    return false;
  }

  // ---- Structural ops ----

  /**
   * Flush the buffer and apply `op` to the table as it is after the flush,
   * as ONE transaction (one undo step), then refocus a cell.
   */
  private applyStructural(
    view: EditorView,
    wrap: HTMLElement,
    op: (text: string, t: TexTable) => TexChange[],
    focus: ((t: TexTable) => { row: number; cell: number }) | null,
  ): void {
    const live = this.locate(view, wrap);
    if (!live) return;
    const doc = view.state.doc;
    const edits = this.sameShape(live) ? this.collectEdits(wrap) : [];
    const a = ChangeSet.of(this.mapEdits(docText(doc), live, edits), doc.length);
    const docA = a.apply(doc);
    const liveA = tableAt(texTablesOf(docA), a.mapPos(live.from, 1));
    if (!liveA) return;
    const b = ChangeSet.of(op(docText(docA), liveA), docA.length);
    if (a.empty && b.empty) return;
    committed.add(wrap);
    const all = a.compose(b);
    view.dispatch({ changes: all, userEvent: 'table.edit.structure' });
    if (!focus) return;
    const lineFrom = lineStartOf(view.state.doc, all.mapPos(live.from, 1));
    const after = this.tableFromLine(view.state.doc, lineFrom);
    if (after) {
      const target = focus(after);
      refocus(view, lineFrom, target.row, target.cell);
    }
  }

  private reveal(view: EditorView, wrap: HTMLElement): void {
    const lineFrom = this.lineFromOf(view, wrap);
    if (lineFrom === null) return;
    this.flush(view, wrap);
    const doc = view.state.doc;
    const live = this.tableFromLine(doc, lineFrom);
    if (!live) return;
    view.dispatch({
      effects: revealTexTable.of({ from: lineStartOf(doc, live.from), to: doc.lineAt(live.to).to }),
      selection: EditorSelection.cursor(live.from),
      scrollIntoView: true,
    });
    view.focus();
  }

  // ---- Cell editing ----

  private enterEdit(td: HTMLElement): void {
    if (td.classList.contains('cm-tex-cell-editing')) return;
    td.classList.add('cm-tex-cell-editing');
    td.setAttribute('contenteditable', 'true');
    td.textContent = cellText.get(td) ?? '';
    this.focused = { row: Number(td.dataset.row), cell: Number(td.dataset.cell) };
    placeCaretEnd(td);
  }

  private leaveEdit(td: HTMLElement): void {
    if (!td.classList.contains('cm-tex-cell-editing')) return;
    const text = td.textContent ?? '';
    cellText.set(td, text);
    td.classList.remove('cm-tex-cell-editing');
    td.removeAttribute('contenteditable');
    renderTexCell(text, td, this.cache);
  }

  private cellAt(wrap: HTMLElement, row: number, col: number): HTMLElement | null {
    for (const td of wrap.querySelectorAll<HTMLElement>(`td[data-row="${row}"]`)) {
      const c = Number(td.dataset.col);
      if (c <= col && col < c + Number(td.dataset.span ?? 1)) return td;
    }
    return null;
  }

  private handleKeydown(view: EditorView, wrap: HTMLElement, e: KeyboardEvent): void {
    const active = document.activeElement as HTMLElement | null;
    if (!active || !wrap.contains(active) || !active.dataset.cell) return;
    if (e.isComposing || e.keyCode === 229) return; // never steal IME keys
    const row = Number(active.dataset.row);
    const nrows = this.table.rows.length;

    // Select-all stays inside the cell: CM6's would grab the document.
    if ((e.metaKey || e.ctrlKey) && (e.key === 'a' || e.key === 'A')) {
      e.preventDefault();
      e.stopPropagation();
      window.getSelection()?.selectAllChildren(active);
      return;
    }

    if (e.key === 'Tab') {
      e.preventDefault();
      const cells = this.cells(wrap);
      const idx = cells.indexOf(active);
      if (e.shiftKey) {
        if (idx > 0) cells[idx - 1].focus();
      } else if (idx < cells.length - 1) {
        cells[idx + 1].focus();
      } else {
        this.applyStructural(
          view,
          wrap,
          (text, t) => insertRowEdit(text, t, t.rows.length - 1, 'below'),
          (t) => ({ row: t.rows.length - 1, cell: 0 }),
        );
      }
      return;
    }

    if (e.key === 'Enter') {
      e.preventDefault();
      const col = Number(active.dataset.col);
      const target = e.shiftKey ? row - 1 : row + 1;
      if (target < 0) return;
      if (target < nrows) {
        this.cellAt(wrap, target, col)?.focus();
        return;
      }
      this.applyStructural(
        view,
        wrap,
        (text, t) => insertRowEdit(text, t, t.rows.length - 1, 'below'),
        (t) => {
          const r = t.rows.length - 1;
          const k = t.rows[r].cells.findIndex((c) => c.col <= col && col < c.col + c.span);
          return { row: r, cell: Math.max(0, k) };
        },
      );
      return;
    }

    if (e.key === 'Escape') {
      e.preventDefault();
      this.leaveEdit(active);
      const lineFrom = this.lineFromOf(view, wrap);
      this.flush(view, wrap);
      const live = lineFrom === null ? null : this.tableFromLine(view.state.doc, lineFrom);
      if (live) {
        view.dispatch({ selection: EditorSelection.cursor(view.state.doc.lineAt(live.to).to) });
      }
      view.focus();
    }
  }

  // ---- Toolbar ----

  private buildToolbar(view: EditorView, wrap: HTMLElement): HTMLElement {
    const bar = document.createElement('div');
    bar.className = 'cm-live-table-toolbar';
    bar.setAttribute('contenteditable', 'false');

    const button = (label: string, title: string, action: () => void): void => {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'cm-live-table-btn';
      b.textContent = label;
      b.title = title;
      // mousedown + preventDefault: the cell keeps focus, so its live text
      // is still readable when the op collects the buffer.
      b.addEventListener('mousedown', (e) => {
        e.preventDefault();
        action();
      });
      bar.appendChild(b);
    };
    const sep = (): void => {
      const s = document.createElement('span');
      s.className = 'cm-live-table-sep';
      bar.appendChild(s);
    };
    const focusedCol = (): number => {
      const c = this.table.rows[this.focused.row]?.cells[this.focused.cell];
      return c ? c.col : 0;
    };
    const sameCell = () => ({ ...this.focused });
    const structural = (
      op: (text: string, t: TexTable) => TexChange[],
      focus: ((t: TexTable) => { row: number; cell: number }) | null = sameCell,
    ) => () => this.applyStructural(view, wrap, op, focus);

    button(
      '↑+',
      'Insert row above',
      structural((text, t) => insertRowEdit(text, t, this.focused.row, 'above')),
    );
    button(
      '↓+',
      'Insert row below',
      structural(
        (text, t) => insertRowEdit(text, t, this.focused.row, 'below'),
        () => ({ row: this.focused.row + 1, cell: this.focused.cell }),
      ),
    );
    button(
      '⌫row',
      'Delete row',
      structural(
        (text, t) => deleteRowEdit(text, t, this.focused.row),
        (t) => ({ row: Math.min(this.focused.row, t.rows.length - 1), cell: 0 }),
      ),
    );
    sep();
    button('+←', 'Insert column left', structural((text, t) => insertColumnEdit(text, t, focusedCol())));
    button(
      '+→',
      'Insert column right',
      structural(
        (text, t) => {
          const c = t.rows[this.focused.row]?.cells[this.focused.cell];
          return insertColumnEdit(text, t, c ? c.col + c.span : focusedCol() + 1);
        },
        () => ({ row: this.focused.row, cell: this.focused.cell + 1 }),
      ),
    );
    button(
      '⌫col',
      'Delete column',
      structural(
        (text, t) => deleteColumnEdit(text, t, focusedCol()),
        (t) => ({ row: this.focused.row, cell: Math.min(this.focused.cell, (t.rows[this.focused.row]?.cells.length ?? 1) - 1) }),
      ),
    );
    sep();
    const align = (a: TexAlign, label: string, title: string) =>
      button(
        label,
        title,
        structural((text, t) => (canSetAlign(t, focusedCol()) ? setAlignEdit(text, t, focusedCol(), a) : [])),
      );
    align('left', '⇤', 'Align column left (l)');
    align('center', '↔', 'Align column center (c)');
    align('right', '⇥', 'Align column right (r)');
    sep();
    button(
      '═',
      'Toggle rule below row',
      structural((text, t) => toggleRuleBelowEdit(text, t, this.focused.row)),
    );
    button('{ }', 'Edit table source', () => this.reveal(view, wrap));
    return bar;
  }

  // ---- Render ----

  toDOM(view: EditorView): HTMLElement {
    const t = this.table;
    const wrap = document.createElement('div');
    wrap.className = 'cm-live-table-wrap cm-tex-table-wrap';
    wrap.classList.add(...calloutTagClasses(this.callout));
    if (this.frame) wrap.classList.add('cm-slide');
    viewForWrap.set(wrap, view);

    const strip = (text: string): HTMLElement => {
      const s = document.createElement('div');
      s.className = 'cm-tex-table-src';
      s.textContent = text;
      return s;
    };

    const scroll = document.createElement('div');
    scroll.className = 'cm-live-table-scroll';
    const table = document.createElement('table');
    table.className = 'cm-live-table cm-tex-table';
    const tbody = document.createElement('tbody');

    const allH: TexRule[] = t.allHLines ? [{ weight: 'thin', from: 0, to: Infinity }] : [];
    const vrules = t.allVLines ? Array(t.ncols + 1).fill(1) : t.spec.vrules;
    t.rows.forEach((row, r) => {
      const tr = document.createElement('tr');
      tr.dataset.row = String(r);
      const last = r === t.rows.length - 1;
      row.cells.forEach((cell, k) => {
        const td = document.createElement('td');
        td.dataset.row = String(r);
        td.dataset.cell = String(k);
        td.dataset.col = String(cell.col);
        // tabindex: focusable while rendered, so a click or Tab can open it.
        td.tabIndex = -1;
        if (cell.span > 1) {
          td.colSpan = cell.span;
          td.dataset.span = String(cell.span);
        }
        const c1 = cell.col + cell.span - 1;
        const align = cell.align ?? t.spec.columns[cell.col]?.align ?? 'left';
        td.classList.add(ALIGN_CLASS[align]);
        if (cell.multirow) td.classList.add('cm-tex-cell-multirow');
        const top = ruleClass([...row.rules, ...allH], cell.col, c1);
        if (top) td.classList.add(`cm-tex-rule-top-${top}`);
        if (last) {
          const bottom = ruleClass([...t.trailingRules, ...allH], cell.col, c1);
          if (bottom) td.classList.add(`cm-tex-rule-bottom-${bottom}`);
        }
        const left = vrules[cell.col] ?? 0;
        if (left) td.classList.add(left > 1 ? 'cm-tex-vrule-left-double' : 'cm-tex-vrule-left');
        if (k === row.cells.length - 1) {
          const right = vrules[c1 + 1] ?? 0;
          if (right) td.classList.add(right > 1 ? 'cm-tex-vrule-right-double' : 'cm-tex-vrule-right');
        }
        const raw = this.raws[r][k];
        cellText.set(td, raw);
        renderTexCell(raw, td, this.cache);

        td.addEventListener('mousedown', (e) => {
          if (td.classList.contains('cm-tex-cell-editing')) return;
          // The rendered DOM is about to be swapped for source: a native caret
          // placed in it would land in a detached node.
          e.preventDefault();
          td.focus();
        });
        td.addEventListener('focus', () => this.enterEdit(td));
        td.addEventListener('blur', () => this.leaveEdit(td));
        td.addEventListener('paste', (e) => {
          e.preventDefault();
          const text = (e.clipboardData?.getData('text/plain') ?? '').replace(/\r?\n/g, ' ');
          document.execCommand('insertText', false, text);
        });
        tr.appendChild(td);
      });
      tbody.appendChild(tr);
    });
    table.appendChild(tbody);
    table.addEventListener('keydown', (e) => this.handleKeydown(view, wrap, e), true);

    // Flush when focus leaves the widget, not on cell-to-cell moves.
    wrap.addEventListener('focusout', (e) => {
      const next = e.relatedTarget as Node | null;
      if (next && wrap.contains(next)) return;
      // Deferred so a programmatic refocus inside the widget cancels it.
      requestAnimationFrame(() => {
        const active = document.activeElement as Node | null;
        if (active && wrap.contains(active)) return;
        this.flush(view, wrap);
      });
    });

    wrap.appendChild(this.buildToolbar(view, wrap));
    if (this.prefix) wrap.appendChild(strip(this.prefix));
    scroll.appendChild(table);
    wrap.appendChild(scroll);
    if (this.suffix) wrap.appendChild(strip(this.suffix));
    return wrap;
  }
}

/** After a re-rendering transaction, focus a cell of the table whose
 *  `\begin` line starts at `lineFrom`. */
function refocus(view: EditorView, lineFrom: number, row: number, cell: number): void {
  requestAnimationFrame(() => {
    for (const wrap of view.dom.querySelectorAll<HTMLElement>('.cm-tex-table-wrap')) {
      let pos: number;
      try {
        pos = view.posAtDOM(wrap);
      } catch {
        continue;
      }
      if (pos !== lineFrom) continue;
      wrap.querySelector<HTMLElement>(`td[data-row="${row}"][data-cell="${cell}"]`)?.focus();
      return;
    }
  });
}
