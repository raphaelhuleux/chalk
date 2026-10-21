// TableWidget: in-place editing of a GFM pipe table, the one place live
// preview uses `contenteditable`. The widget wrap stays non-editable (CM6's
// default) and each <th>/<td> is an editable island. CM6's DOMObserver ignores
// mutations under widgets, so edits buffer in the DOM and flush to the pipe
// source as ONE transaction on blur, Escape, or a structural op.
//
// Cells render plain text (v1). Don't add rich in-cell rendering without
// weighing the selection-mapping cost.
//
// Positions come from `posAtDOM` at action time, never stored, so reused DOM
// can't dispatch into a stale range.

import { EditorView, WidgetType } from '@codemirror/view';
import { EditorSelection, type Text } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import { scanCallouts } from './md-callout-plugin';
import { calloutTagClasses, sameCalloutTag, type CalloutTag } from './callout-core';
import {
  type TableModel,
  type Align,
  serializeTable,
  normalizeShape,
  parseTable,
  escapeCell,
  unescapeCell,
  insertRow,
  deleteRow,
  insertCol,
  deleteCol,
  setAlign,
} from './table-model';
import '../styles/table.css';

type RowKey = 'header' | number;

// The view that built each wrap, so destroy(dom) can reach it for a
// last-chance flush.
const viewForWrap = new WeakMap<HTMLElement, EditorView>();

/**
 * Where a `Table` node's content ends. Lezer's GFM parser continues a table
 * through any non-blank line, so a callout's `:::` close fence right under the
 * last row lands inside the node. That fence is excluded so no flush can
 * overwrite it; a stray `:::` outside any callout stays table content.
 */
export function tableContentTo(doc: Text, from: number, to: number): number {
  const startLine = doc.lineAt(from).number;
  const endLine = doc.lineAt(Math.max(from, to - 1)).number;
  if (endLine <= startLine) return to;
  for (const r of scanCallouts(doc)) {
    if (r.closeLine === endLine && r.openLine < startLine) {
      return Math.min(to, doc.line(endLine - 1).to);
    }
  }
  return to;
}

interface TableRange {
  from: number;
  to: number;
}

function placeCaretEnd(el: HTMLElement): void {
  el.focus();
  const range = document.createRange();
  range.selectNodeContents(el);
  range.collapse(false);
  const sel = window.getSelection();
  sel?.removeAllRanges();
  sel?.addRange(range);
}

const ALIGN_CLASS: Record<Align, string> = {
  none: '',
  left: 'cm-live-table-cell--left',
  center: 'cm-live-table-cell--center',
  right: 'cm-live-table-cell--right',
};

export class TableWidget extends WidgetType {
  /** Updated on focusin; drives which row/col structural ops target. */
  private focused: { row: RowKey; col: number } = { row: 'header', col: 0 };
  /** `serializeTable(model)`, computed once: `eq` compares it on every
   *  rebuild of the table field. */
  private sourceCache: string | null = null;

  constructor(
    readonly model: TableModel,
    // Set inside a callout so the wrap continues the box: a block widget isn't
    // a `.cm-line`, so the per-line tint/border can't reach it.
    readonly callout: CalloutTag | null = null,
  ) {
    super();
  }

  private get source(): string {
    return (this.sourceCache ??= serializeTable(this.model));
  }

  eq(other: TableWidget): boolean {
    // Render-equality, not position, so edits elsewhere reuse the DOM and keep
    // a focused cell's caret.
    return (
      this.source === other.source && sameCalloutTag(this.callout, other.callout)
    );
  }

  ignoreEvent(): boolean {
    return true;
  }

  // ---- Live range lookup ----

  private tableRange(view: EditorView, el: HTMLElement): TableRange | null {
    let pos: number;
    try {
      pos = view.posAtDOM(el);
    } catch {
      return null;
    }
    const tree = syntaxTree(view.state);
    const doc = view.state.doc;
    const trim = (from: number, to: number): TableRange => ({
      from,
      to: tableContentTo(doc, from, to),
    });
    let node: ReturnType<typeof tree.resolveInner> | null = tree.resolveInner(pos, 1);
    while (node && node.name !== 'Table') node = node.parent;
    if (node) return trim(node.from, node.to);
    // Fallback: nearest Table node by start.
    let best: TableRange | null = null;
    tree.iterate({
      enter(n) {
        if (n.name !== 'Table') return;
        if (!best || Math.abs(n.from - pos) < Math.abs(best.from - pos)) {
          best = { from: n.from, to: n.to };
        }
      },
    });
    // Assigned inside the callback, which TS narrowing can't see.
    const found = best as TableRange | null;
    return found ? trim(found.from, found.to) : null;
  }

  // ---- DOM <-> model ----

  private readModel(table: HTMLTableElement): TableModel {
    const header = Array.from(table.querySelectorAll('thead th')).map((th) =>
      escapeCell(th.textContent ?? ''),
    );
    const rows = Array.from(table.querySelectorAll('tbody tr')).map((tr) =>
      Array.from(tr.querySelectorAll('td')).map((td) => escapeCell(td.textContent ?? '')),
    );
    return normalizeShape({ aligns: this.model.aligns.slice(), header, rows });
  }

  // ---- Flush buffered edits to the document ----

  private flush(view: EditorView, table: HTMLTableElement): void {
    const range = this.tableRange(view, table);
    if (!range) return;
    const serialized = serializeTable(this.readModel(table));
    // Unedited cells must not rewrite the source: a compact table never equals
    // the padded form, and focus leaves on every window switch (see
    // docs/issues/2026-10-19-table-blur-shadows-agent-writes.md).
    if (serialized === this.source) return;
    if (serialized === view.state.doc.sliceString(range.from, range.to)) return;
    view.dispatch({
      changes: { from: range.from, to: range.to, insert: serialized },
      userEvent: 'table.edit',
    });
  }

  /**
   * Last-chance flush when the DOM is about to be discarded with buffered edits
   * (the deferred focusout flush dies on detached elements). Positions are read
   * synchronously while the DOM is still linked; only the dispatch is deferred,
   * since widget teardown runs inside a CM6 update.
   *
   * Drops the edit whenever the range can't be trusted: `posAtDOM` fails, the
   * source there no longer matches the model this DOM was built from (a host
   * update rewrote it), the doc changes before the microtask, or the DOM
   * survives (the normal flush still owns it). A dropped edit is recoverable;
   * a dispatch into a stale range is not.
   */
  private flushBeforeDetach(view: EditorView, wrap: HTMLElement): void {
    const table = wrap.querySelector<HTMLTableElement>('table.cm-live-table');
    if (!table) return;

    const original = this.source;
    const serialized = serializeTable(this.readModel(table));
    if (serialized === original) return; // nothing buffered

    const range = this.tableRange(view, table);
    if (!range) return; // DOM already unlinked
    let atRange: string;
    try {
      atRange = view.state.doc.sliceString(range.from, range.to);
    } catch {
      return;
    }
    // The range must still hold the exact table this DOM was built from.
    if (serializeTable(parseTable(atRange)) !== original) return;
    if (serialized === atRange) return;

    const docBefore = view.state.doc;
    queueMicrotask(() => {
      // Text is immutable: any intervening transaction (even a competing flush)
      // invalidates the range.
      if (view.state.doc !== docBefore) return;
      // The DOM survived (tile reused): leave the buffer to the normal flush so
      // a focused cell keeps its caret.
      if (view.dom.contains(wrap)) return;
      try {
        view.dispatch({
          changes: { from: range.from, to: range.to, insert: serialized },
          userEvent: 'table.edit',
        });
      } catch {
        // View destroyed: drop.
      }
    });
  }

  /** In real teardown the tile is usually unlinked first, so posAtDOM fails
   *  and this drops; updateDOM is the reliable hook. Kept for removal paths
   *  where the position still resolves. */
  destroy(dom: HTMLElement): void {
    const view = viewForWrap.get(dom);
    if (view) this.flushBeforeDetach(view, dom);
  }

  /**
   * Called on the new widget with the old one as `from`. We never patch in
   * place (false: rebuild via toDOM), but this is the one moment the outgoing
   * DOM is still linked, so flush its buffer here, validated against the model
   * that built it (`from`).
   */
  updateDOM(dom: HTMLElement, view: EditorView, from: TableWidget): boolean {
    from.flushBeforeDetach(view, dom);
    return false;
  }

  // ---- Structural ops (toolbar + navigation that grows the table) ----

  private applyStructural(
    view: EditorView,
    table: HTMLTableElement,
    transform: (m: TableModel) => TableModel,
    nextFocus: (m: TableModel) => { row: RowKey; col: number },
  ): void {
    const range = this.tableRange(view, table);
    if (!range) return;
    const current = this.readModel(table); // keeps the un-flushed buffer
    const next = transform(current);
    const focus = nextFocus(next);
    view.dispatch({
      changes: { from: range.from, to: range.to, insert: serializeTable(next) },
      userEvent: 'table.edit.structure',
    });
    this.refocus(view, range.from, focus.row, focus.col);
  }

  /** After a re-rendering transaction, restore focus to a specific cell.
   *  Row/column ops keep the table's start position, so `from` is stable. */
  private refocus(view: EditorView, from: number, row: RowKey, col: number): void {
    requestAnimationFrame(() => {
      const table = this.findTableAt(view, from);
      if (!table) return;
      const sel =
        row === 'header'
          ? table.querySelector<HTMLElement>(`thead th[data-col="${col}"]`)
          : table.querySelector<HTMLElement>(`tbody tr[data-row="${row}"] td[data-col="${col}"]`);
      if (sel) placeCaretEnd(sel);
    });
  }

  private findTableAt(view: EditorView, from: number): HTMLTableElement | null {
    const tables = view.dom.querySelectorAll<HTMLTableElement>('table.cm-live-table');
    for (const t of tables) {
      const r = this.tableRange(view, t);
      if (r && r.from === from) return t;
    }
    return null;
  }

  // ---- Cell navigation ----

  private cellOrder(table: HTMLTableElement): HTMLElement[] {
    return Array.from(table.querySelectorAll<HTMLElement>('th[data-col], td[data-col]'));
  }

  private handleKeydown(view: EditorView, table: HTMLTableElement, e: KeyboardEvent): void {
    const active = document.activeElement as HTMLElement | null;
    if (!active || !table.contains(active)) return;
    if (e.isComposing || e.keyCode === 229) return; // never steal IME keys

    // Select-all stays inside the cell: CM6's would grab the whole document
    // and the next keystroke would replace it.
    if ((e.metaKey || e.ctrlKey) && (e.key === 'a' || e.key === 'A')) {
      e.preventDefault();
      e.stopPropagation();
      const sel = window.getSelection();
      if (sel) sel.selectAllChildren(active);
      return;
    }

    if (e.key === 'Tab') {
      e.preventDefault();
      const cells = this.cellOrder(table);
      const idx = cells.indexOf(active);
      if (e.shiftKey) {
        if (idx > 0) placeCaretEnd(cells[idx - 1]);
        return;
      }
      if (idx < cells.length - 1) {
        placeCaretEnd(cells[idx + 1]);
      } else {
        // Past the last cell: append a row and land in its first cell.
        const lastRow = this.readModel(table).rows.length;
        this.applyStructural(
          view,
          table,
          (m) => insertRow(m, m.rows.length - 1, 'below'),
          () => ({ row: lastRow, col: 0 }),
        );
      }
      return;
    }

    if (e.key === 'Enter') {
      e.preventDefault();
      const { row, col } = this.cellPosOf(active);
      const rowCount = this.readModel(table).rows.length;
      if (row === 'header') {
        if (rowCount > 0) this.focusCell(table, 0, col);
        else this.applyStructural(view, table, (m) => insertRow(m, -1, 'below'), () => ({ row: 0, col }));
      } else if (row < rowCount - 1) {
        this.focusCell(table, row + 1, col);
      } else {
        this.applyStructural(
          view,
          table,
          (m) => insertRow(m, m.rows.length - 1, 'below'),
          () => ({ row: rowCount, col }),
        );
      }
      return;
    }

    if (e.key === 'Escape') {
      e.preventDefault();
      this.flush(view, table);
      const range = this.tableRange(view, table);
      if (range) {
        view.dispatch({ selection: EditorSelection.cursor(range.to) });
      }
      view.focus();
      return;
    }
  }

  private cellPosOf(cell: HTMLElement): { row: RowKey; col: number } {
    const col = Number(cell.dataset.col ?? 0);
    const rowAttr = cell.dataset.row;
    return { row: rowAttr === undefined ? 'header' : Number(rowAttr), col };
  }

  private focusCell(table: HTMLTableElement, row: RowKey, col: number): void {
    const sel =
      row === 'header'
        ? table.querySelector<HTMLElement>(`thead th[data-col="${col}"]`)
        : table.querySelector<HTMLElement>(`tbody tr[data-row="${row}"] td[data-col="${col}"]`);
    if (sel) placeCaretEnd(sel);
  }

  // ---- Toolbar ----

  private buildToolbar(view: EditorView, getTable: () => HTMLTableElement): HTMLElement {
    const bar = document.createElement('div');
    bar.className = 'cm-live-table-toolbar';
    bar.setAttribute('contenteditable', 'false');

    const button = (label: string, title: string, action: () => void): HTMLButtonElement => {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'cm-live-table-btn';
      b.textContent = label;
      b.title = title;
      // mousedown + preventDefault keeps the cell from blurring (and flushing)
      // before the structural op reads the live DOM.
      b.addEventListener('mousedown', (e) => {
        e.preventDefault();
        action();
      });
      return b;
    };

    const bodyIndex = (): number => (this.focused.row === 'header' ? -1 : this.focused.row);

    bar.appendChild(
      button('↑+', 'Insert row above', () =>
        this.applyStructural(
          view,
          getTable(),
          (m) => insertRow(m, bodyIndex(), 'above'),
          () => ({ row: Math.max(0, bodyIndex()), col: this.focused.col }),
        ),
      ),
    );
    bar.appendChild(
      button('↓+', 'Insert row below', () =>
        this.applyStructural(
          view,
          getTable(),
          (m) => insertRow(m, bodyIndex(), 'below'),
          () => ({ row: bodyIndex() + 1, col: this.focused.col }),
        ),
      ),
    );
    bar.appendChild(
      button('⌫row', 'Delete row', () => {
        if (this.focused.row === 'header') return;
        const r = this.focused.row;
        this.applyStructural(
          view,
          getTable(),
          (m) => deleteRow(m, r),
          (m) => ({ row: m.rows.length === 0 ? 'header' : Math.min(r, m.rows.length - 1), col: this.focused.col }),
        );
      }),
    );

    const sep = document.createElement('span');
    sep.className = 'cm-live-table-sep';
    bar.appendChild(sep);

    bar.appendChild(
      button('+←', 'Insert column left', () =>
        this.applyStructural(
          view,
          getTable(),
          (m) => insertCol(m, this.focused.col, 'left'),
          () => ({ row: this.focused.row, col: this.focused.col }),
        ),
      ),
    );
    bar.appendChild(
      button('+→', 'Insert column right', () =>
        this.applyStructural(
          view,
          getTable(),
          (m) => insertCol(m, this.focused.col, 'right'),
          () => ({ row: this.focused.row, col: this.focused.col + 1 }),
        ),
      ),
    );
    bar.appendChild(
      button('⌫col', 'Delete column', () => {
        const c = this.focused.col;
        this.applyStructural(
          view,
          getTable(),
          (m) => deleteCol(m, c),
          (m) => ({ row: this.focused.row, col: Math.min(c, m.header.length - 1) }),
        );
      }),
    );

    const sep2 = document.createElement('span');
    sep2.className = 'cm-live-table-sep';
    bar.appendChild(sep2);

    const align = (a: Align, label: string, title: string) =>
      button(label, title, () =>
        this.applyStructural(
          view,
          getTable(),
          (m) => setAlign(m, this.focused.col, a),
          () => ({ row: this.focused.row, col: this.focused.col }),
        ),
      );
    bar.appendChild(align('left', '⇤', 'Align left'));
    bar.appendChild(align('center', '↔', 'Align center'));
    bar.appendChild(align('right', '⇥', 'Align right'));

    return bar;
  }

  // ---- Render ----

  toDOM(view: EditorView): HTMLElement {
    const model = normalizeShape(this.model);
    const wrap = document.createElement('div');
    wrap.className = 'cm-live-table-wrap';
    wrap.classList.add(...calloutTagClasses(this.callout));
    viewForWrap.set(wrap, view);

    const scroll = document.createElement('div');
    scroll.className = 'cm-live-table-scroll';

    const table = document.createElement('table');
    table.className = 'cm-live-table';

    const setupCell = (cell: HTMLElement, text: string, col: number, row?: number) => {
      // Attribute, not property: jsdom only honors the attribute for
      // focusability.
      cell.setAttribute('contenteditable', 'true');
      cell.dataset.col = String(col);
      if (row !== undefined) cell.dataset.row = String(row);
      const cls = ALIGN_CLASS[model.aligns[col] ?? 'none'];
      if (cls) cell.classList.add(cls);
      cell.textContent = unescapeCell(text);
      cell.addEventListener('focusin', () => {
        this.focused = { row: row === undefined ? 'header' : row, col };
      });
      cell.addEventListener('paste', (e) => {
        e.preventDefault();
        const t = (e.clipboardData?.getData('text/plain') ?? '').replace(/\r?\n/g, ' ');
        document.execCommand('insertText', false, t);
      });
    };

    const thead = document.createElement('thead');
    const htr = document.createElement('tr');
    model.header.forEach((cell, col) => {
      const th = document.createElement('th');
      setupCell(th, cell, col);
      htr.appendChild(th);
    });
    thead.appendChild(htr);
    table.appendChild(thead);

    const tbody = document.createElement('tbody');
    model.rows.forEach((row, r) => {
      const tr = document.createElement('tr');
      tr.dataset.row = String(r);
      row.forEach((cell, col) => {
        const td = document.createElement('td');
        setupCell(td, cell, col, r);
        tr.appendChild(td);
      });
      tbody.appendChild(tr);
    });
    table.appendChild(tbody);

    table.addEventListener('keydown', (e) => this.handleKeydown(view, table, e), true);

    // Flush when focus leaves the widget, not on cell-to-cell moves.
    wrap.addEventListener('focusout', (e) => {
      const next = e.relatedTarget as Node | null;
      if (next && wrap.contains(next)) return;
      // Defer so a programmatic refocus within the widget can cancel the flush.
      requestAnimationFrame(() => {
        const active = document.activeElement as Node | null;
        if (active && wrap.contains(active)) return;
        this.flush(view, table);
      });
    });

    scroll.appendChild(table);
    wrap.appendChild(this.buildToolbar(view, () => table));
    wrap.appendChild(scroll);
    return wrap;
  }

  /** The read path a flush uses, for tests. */
  domToModel(table: HTMLTableElement): TableModel {
    return this.readModel(table);
  }
}
