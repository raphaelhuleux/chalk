import {
  codeFolding,
  foldEffect,
  foldService,
  foldedRanges,
  unfoldAll,
  unfoldCode,
  unfoldEffect,
} from '@codemirror/language';
import {
  EditorSelection,
  EditorState,
  Prec,
  type Extension,
  type StateEffect,
  type Transaction,
  type TransactionSpec,
} from '@codemirror/state';
import { EditorView, ViewPlugin, keymap, type Command, type ViewUpdate } from '@codemirror/view';
import { dispatchVerticalStop, moreWrappedRows, verticalGoalX } from './callout-core';
import {
  ancestorsAt,
  foldableNodes,
  leadingWhitespace,
  outlineNodeAt,
  type OutlineNode,
} from './md-outline-tree';

/**
 * Markdown folding: a heading's section or a list item's subtree collapses
 * behind its head line. The folded ranges are CodeMirror's own `foldState`
 * (user state, outside the preview compartment, so they survive view-mode
 * switches), and `foldService` answers from md-outline-tree.ts, so CM6's own
 * fold commands agree with ours. This module keeps the hidden text safe:
 *  - a fold is atomic, so Left/Right and selections step over it whole;
 *  - a single Backspace/Delete that would eat a fold unfolds it instead;
 *  - text inserted at a fold's far edge (End on the head row) lands on the
 *    last hidden line, so the fold opens;
 *  - Up/Down next to a fold take the geometric move, before the line-adjacent
 *    stop keymaps (fences, display math, tables) can land inside it.
 * Key policy: docs/specs/2026-11-07-markdown-outliner.md.
 */

export interface FoldRange {
  from: number;
  to: number;
}

/** The range a fold of `node` hides: head-line end to subtree end. */
function foldRangeOf(state: EditorState, node: OutlineNode): FoldRange | null {
  if (node.end <= node.headEnd) return null;
  return { from: state.doc.line(node.headEnd).to, to: state.doc.line(node.end).to };
}

export function foldRangeAtLine(state: EditorState, lineNo: number): FoldRange | null {
  const node = outlineNodeAt(state, lineNo);
  return node ? foldRangeOf(state, node) : null;
}

/** Folds that touch `pos` (start ≤ pos ≤ end). */
function foldsAt(state: EditorState, pos: number): FoldRange[] {
  const out: FoldRange[] = [];
  foldedRanges(state).between(pos, pos, (from, to) => {
    out.push({ from, to });
  });
  return out;
}

/** The fold hanging off line `lineNo`'s end (its head row), if any. */
export function foldOnLine(state: EditorState, lineNo: number): FoldRange | null {
  const end = state.doc.line(lineNo).to;
  return foldsAt(state, end).find((r) => r.from === end) ?? null;
}

/** True when `pos` is hidden by a fold (strictly after its start). */
function insideFold(state: EditorState, pos: number): boolean {
  return foldsAt(state, pos).some((r) => r.from < pos && pos <= r.to);
}

function isFolded(state: EditorState, r: FoldRange): boolean {
  return foldsAt(state, r.from).some((f) => f.from === r.from && f.to === r.to);
}

function foldSpec(state: EditorState, r: FoldRange): TransactionSpec {
  const head = state.selection.main.head;
  // The caret can't stay hidden: park it at the end of the head row.
  const selection = head > r.from && head <= r.to ? EditorSelection.cursor(r.from) : undefined;
  return { effects: foldEffect.of(r), selection };
}

/** Fold the innermost unfolded node around the caret (again: its parent). */
export const foldAtCaret: Command = (view) => {
  const { state } = view;
  const line = state.doc.lineAt(state.selection.main.head).number;
  const r = ancestorsAt(state, line)
    .reverse()
    .map((n) => foldRangeOf(state, n))
    .find((f) => f && !isFolded(state, f));
  if (!r) return false;
  view.dispatch(foldSpec(state, r));
  return true;
};

/** Fold or unfold the node on `lineNo` (the chevron's click). */
export function toggleFoldAtLine(view: EditorView, lineNo: number): boolean {
  const { state } = view;
  const folded = foldOnLine(state, lineNo);
  if (folded) {
    view.dispatch({ effects: unfoldEffect.of(folded) });
    return true;
  }
  const r = foldRangeAtLine(state, lineNo);
  if (!r) return false;
  view.dispatch(foldSpec(state, r));
  return true;
}

/**
 * Show the outline down to `level`: headings of that level and deeper fold.
 * A document without headings folds its list items at that nesting depth
 * (level 1 = top-level items). Level 0 unfolds everything.
 */
export function foldToLevel(view: EditorView, level: number): boolean {
  const { state } = view;
  const effects: StateEffect<unknown>[] = [];
  foldedRanges(state).between(0, state.doc.length, (from, to) => {
    effects.push(unfoldEffect.of({ from, to }));
  });
  const head = state.selection.main.head;
  let park: number | null = null;
  if (level > 0) {
    const nodes = foldableNodes(state);
    const headings = nodes.some((n) => n.kind === 'heading');
    const widths = [...new Set(nodes.filter((n) => n.kind === 'item').map((n) => n.level))].sort(
      (a, b) => a - b,
    );
    let coveredTo = 0;
    for (const node of nodes) {
      const depth = headings
        ? node.kind === 'heading'
          ? node.level
          : 0
        : widths.indexOf(node.level) + 1;
      if (depth < level || node.line <= coveredTo) continue;
      const r = foldRangeOf(state, node)!;
      effects.push(foldEffect.of(r));
      coveredTo = node.end;
      // Folds don't nest here, so at most one covers the caret.
      if (r.from < head && head <= r.to) park = r.from;
    }
  }
  if (!effects.length) return false;
  view.dispatch({ effects, selection: park === null ? undefined : EditorSelection.cursor(park) });
  return true;
}

// --- Keeping hidden text safe ---------------------------------------------------

/** A one-key delete from an empty caret that would eat a fold unfolds it
 *  instead: the user can't see what they would be deleting. */
const protectHidden = EditorState.transactionFilter.of((tr: Transaction) => {
  if (!tr.docChanged) return tr;
  if (!tr.isUserEvent('delete.backward') && !tr.isUserEvent('delete.forward')) return tr;
  const folds = foldedRanges(tr.startState);
  if (!folds.size || !tr.startState.selection.main.empty) return tr;
  const unfold: StateEffect<FoldRange>[] = [];
  tr.changes.iterChangedRanges((fromA, toA) => {
    folds.between(fromA, toA, (from, to) => {
      // Overlap, or Backspace at the next line's start (it would join that
      // line onto the last hidden one).
      if ((fromA < to && toA > from) || fromA === to) unfold.push(unfoldEffect.of({ from, to }));
    });
  });
  if (!unfold.length) return tr;
  return { effects: unfold, selection: tr.startState.selection };
});

/** Text inserted at a fold's far edge lands on its last hidden line, so the
 *  fold opens, whatever the command. A line break first leaves that line
 *  alone (Enter after a folded item), so the fold stays. Effects are in
 *  post-change positions, mapped the way foldState maps the fold itself. */
const revealOnEdgeInput = EditorState.transactionExtender.of((tr: Transaction) => {
  if (!tr.docChanged) return null;
  const folds = foldedRanges(tr.startState);
  if (!folds.size) return null;
  const effects: StateEffect<FoldRange>[] = [];
  tr.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
    if (fromA !== toA || !inserted.length || inserted.sliceString(0, 1) === '\n') return;
    folds.between(fromA, fromA, (from, to) => {
      if (to === fromA) {
        effects.push(
          unfoldEffect.of({ from: tr.changes.mapPos(from, 1), to: tr.changes.mapPos(to, -1) }),
        );
      }
    });
  });
  return effects.length ? { effects } : null;
});

const atomicFolds = EditorView.atomicRanges.of((view) => foldedRanges(view.state));

// --- Vertical motion -------------------------------------------------------------

/**
 * Up/Down when the adjacent document line is hidden by a fold: take the
 * geometric move (which skips the fold's rows) and keep the goal column.
 * Prec.highest because the table keymap sits in previewCompartment, ahead of
 * anything setup.ts lists later: the fence, math and table stops target
 * `line ± 1` and would land inside the fold and unfold it. setup.ts lists it
 * after the completion extension, so an open popup keeps Up/Down.
 */
function crossFold(forward: boolean): Command {
  return (view) => {
    const { state } = view;
    const sel = state.selection.main;
    if (!sel.empty || !foldedRanges(state).size) return false;
    const line = state.doc.lineAt(sel.head);
    const target = forward ? line.to + 1 : line.from - 1;
    if (target < 0 || target > state.doc.length) return false;
    // Going down, the caret's own row continues past a fold on this line.
    const hidden =
      insideFold(state, target) || (forward && foldOnLine(state, line.number) !== null);
    if (!hidden || moreWrappedRows(view, forward ? 1 : -1)) return false;
    const goalX = verticalGoalX(view);
    const moved = view.moveVertically(
      EditorSelection.cursor(sel.head, sel.assoc, undefined, goalX),
      forward,
    );
    if (moved.head === sel.head) return false;
    dispatchVerticalStop(view, moved.head);
    return true;
  };
}

export const mdFoldArrowKeymap: Extension = Prec.highest(
  keymap.of([
    { key: 'ArrowDown', run: crossFold(true) },
    { key: 'ArrowUp', run: crossFold(false) },
  ]),
);

// --- Chevrons ----------------------------------------------------------------------

const HANDLE_GAP = 18; // px from the marker's left edge to the chevron's

interface Handle {
  line: number;
  left: number;
  top: number;
  height: number;
  folded: boolean;
}

/**
 * Fold chevrons in an overlay inside `.cm-scroller`, outside `.cm-content`:
 * no caret stop, no layout change, and CM6's own mouse handling never sees the
 * click. The hovered foldable row shows one; every folded row keeps one.
 */
const chevronPlugin = ViewPlugin.fromClass(
  class {
    dom: HTMLElement;
    /** Line under the pointer, foldable or not; null off the text. */
    pointerLine: number | null = null;
    hoverLine: number | null = null;

    constructor(readonly view: EditorView) {
      this.dom = document.createElement('div');
      this.dom.className = 'cm-md-fold-handles';
      this.dom.setAttribute('aria-hidden', 'true');
      view.scrollDOM.appendChild(this.dom);
      view.scrollDOM.addEventListener('mousemove', this.onMove);
      view.scrollDOM.addEventListener('mouseleave', this.onLeave);
      this.dom.addEventListener('mousedown', this.onDown);
      this.schedule();
    }

    update(u: ViewUpdate) {
      if (u.docChanged) this.pointerLine = null;
      if (
        u.docChanged ||
        u.viewportChanged ||
        u.geometryChanged ||
        foldedRanges(u.startState) !== foldedRanges(u.state)
      ) {
        this.schedule();
      }
    }

    onMove = (e: MouseEvent) => {
      const { view } = this;
      const block = view.lineBlockAtHeight(e.clientY - view.documentTop);
      const n = view.state.doc.lineAt(block.from).number;
      if (n === this.pointerLine) return; // same row: nothing to ask
      this.pointerLine = n;
      const hover = foldRangeAtLine(view.state, n) ? n : null;
      if (hover !== this.hoverLine) {
        this.hoverLine = hover;
        this.schedule();
      }
    };

    onLeave = () => {
      this.pointerLine = null;
      if (this.hoverLine !== null) {
        this.hoverLine = null;
        this.schedule();
      }
    };

    onDown = (e: MouseEvent) => {
      const el = (e.target as HTMLElement).closest('[data-line]') as HTMLElement | null;
      if (!el) return;
      e.preventDefault();
      e.stopPropagation();
      toggleFoldAtLine(this.view, Number(el.dataset.line));
    };

    schedule() {
      this.view.requestMeasure({ key: this, read: () => this.measure(), write: (h) => this.draw(h) });
    }

    measure(): Handle[] {
      const { view } = this;
      const { state } = view;
      const lines = new Set<number>();
      for (const { from, to } of view.visibleRanges) {
        foldedRanges(state).between(from, to, (a) => {
          lines.add(state.doc.lineAt(a).number);
        });
      }
      if (this.hoverLine !== null && this.hoverLine <= state.doc.lines) lines.add(this.hoverLine);
      // Screen to overlay coordinates (the overlay scrolls with the content).
      const box = view.scrollDOM.getBoundingClientRect();
      const ox = box.left - view.scrollDOM.scrollLeft * view.scaleX;
      const oy = box.top - view.scrollDOM.scrollTop * view.scaleY;
      const out: Handle[] = [];
      for (const n of lines) {
        const line = state.doc.line(n);
        // A line hidden by zoom (or a stale hover) has no row to sit on.
        if (!view.visibleRanges.some((r) => r.from <= line.from && line.from <= r.to)) continue;
        const at = view.coordsAtPos(line.from + leadingWhitespace(line.text).length, 1);
        if (!at) continue;
        out.push({
          line: n,
          left: Math.max(0, (at.left - ox) / view.scaleX - HANDLE_GAP),
          top: (at.top - oy) / view.scaleY,
          height: (at.bottom - at.top) / view.scaleY,
          folded: foldOnLine(state, n) !== null,
        });
      }
      return out;
    }

    draw(handles: Handle[]) {
      this.dom.textContent = '';
      for (const h of handles) {
        const el = document.createElement('div');
        el.className = 'cm-md-fold-handle' + (h.folded ? ' cm-md-fold-handle-folded' : '');
        el.dataset.line = String(h.line);
        el.style.left = `${h.left}px`;
        el.style.top = `${h.top}px`;
        el.style.height = `${h.height}px`;
        el.title = h.folded ? 'Unfold' : 'Fold';
        this.dom.appendChild(el);
      }
    }

    destroy() {
      this.view.scrollDOM.removeEventListener('mousemove', this.onMove);
      this.view.scrollDOM.removeEventListener('mouseleave', this.onLeave);
      this.dom.remove();
    }
  },
);

// --- Placeholder and theme -----------------------------------------------------------

function placeholderDOM(_view: EditorView, onclick: (e: Event) => void, prepared: unknown): HTMLElement {
  const el = document.createElement('span');
  el.className = 'cm-md-fold-placeholder';
  el.textContent = '…';
  const lines = prepared as number;
  el.title = `${lines} hidden line${lines === 1 ? '' : 's'}`;
  el.setAttribute('aria-label', el.title);
  el.onclick = onclick;
  return el;
}

const foldTheme = EditorView.baseTheme({
  '.cm-md-fold-handles': {
    position: 'absolute',
    top: 0,
    left: 0,
    width: 0,
    height: 0,
    zIndex: 3,
  },
  '.cm-md-fold-handle': {
    position: 'absolute',
    width: '14px',
    cursor: 'pointer',
    opacity: 0.45,
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
  },
  '.cm-md-fold-handle:hover': { opacity: 0.9 },
  // A CSS chevron: two borders of a small square, rotated.
  '.cm-md-fold-handle::before': {
    content: '""',
    width: '5px',
    height: '5px',
    borderRight: '1.5px solid currentColor',
    borderBottom: '1.5px solid currentColor',
    transform: 'rotate(45deg) translate(-1px, -1px)',
  },
  '.cm-md-fold-handle-folded::before': {
    transform: 'rotate(-45deg) translate(-1px, 0)',
  },
  '.cm-md-fold-placeholder': {
    display: 'inline-block',
    margin: '0 0.35em',
    padding: '0 0.4em',
    borderRadius: '4px',
    lineHeight: '1.2',
    cursor: 'pointer',
    opacity: 0.6,
    background: 'var(--vscode-editorWidget-background, rgba(127, 127, 127, 0.15))',
    border: '1px solid var(--vscode-editorWidget-border, rgba(127, 127, 127, 0.3))',
  },
  '.cm-md-fold-placeholder:hover': { opacity: 1 },
});

// --- Wiring ------------------------------------------------------------------------------

/** Everything folding needs except the arrow guard, which setup.ts places
 *  after the completion extension. */
export function mdFoldExtension(): Extension {
  return [
    // Ahead of lang-markdown's own heading service, so CM6's fold commands
    // (unfoldCode, toggleFold) use the outline's ranges.
    Prec.high(
      foldService.of((state, lineStart) =>
        foldRangeAtLine(state, state.doc.lineAt(lineStart).number),
      ),
    ),
    codeFolding({
      preparePlaceholder: (state, range) =>
        state.doc.lineAt(range.to).number - state.doc.lineAt(range.from).number,
      placeholderDOM,
    }),
    atomicFolds,
    protectHidden,
    revealOnEdgeInput,
    chevronPlugin,
    foldTheme,
    keymap.of([
      { key: 'Mod-Alt-[', run: foldAtCaret },
      { key: 'Mod-Alt-]', run: unfoldCode },
      { key: 'Mod-Alt-0', run: unfoldAll },
      ...[1, 2, 3, 4, 5, 6].map((n) => ({
        key: `Mod-Alt-${n}`,
        run: (v: EditorView) => foldToLevel(v, n),
      })),
    ]),
  ];
}
