// tableField: every GFM `Table` node becomes a block-replace TableWidget
// (editing happens in its contenteditable cells, see table-widget.ts). The
// range is an atomicRange so the CM6 caret never lands in the pipe source.
// Always rendered, no caret reveal; the selection only matters at a callout's
// close fence (see calloutBlockAt).

import { Decoration, DecorationSet, EditorView, keymap } from '@codemirror/view';
import {
  EditorSelection,
  EditorState,
  Extension,
  Prec,
  RangeSetBuilder,
  SelectionRange,
  StateField,
  Text,
} from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import { parseTable } from './table-model';
import { TableWidget, tableContentTo } from './table-widget';
import {
  calloutBlockAt,
  dispatchVerticalStop,
  recordVerticalLanding,
  sameColumnOnLine,
  verticalGoalX,
} from './callout-core';
import { scanCallouts } from './md-callout-plugin';

function buildTableDecorations(state: EditorState): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const tree = syntaxTree(state);
  const ranges: Array<{ from: number; to: number; deco: Decoration }> = [];

  tree.iterate({
    enter(node) {
      if (node.name === 'Paragraph') return false; // inline content only
      if (node.name !== 'Table') return;
      const from = node.from;
      const to = tableContentTo(state.doc, from, node.to);
      const model = parseTable(state.doc.sliceString(from, to));
      // Inside a callout the widget carries the callout type, and as the box's
      // last element the replace extends through the collapsed `:::` fence
      // (`hideTo`) so no residue row appears. A caret on the fence shrinks it
      // back, revealing the `:::`. Same as the display-math widgets.
      const callout = calloutBlockAt(state.doc, scanCallouts, from, to, state.selection.main);
      ranges.push({
        from,
        to: callout?.hideTo ?? to,
        deco: Decoration.replace({
          widget: new TableWidget(
            model,
            callout ? { type: callout.type, bottom: callout.bottom } : null,
          ),
          block: true,
        }),
      });
      return false; // rows and cells hold no tables
    },
  });

  ranges.sort((a, b) => a.from - b.from || a.to - b.to);
  for (const { from, to, deco } of ranges) builder.add(from, to, deco);
  return builder.finish();
}

/** Whether either end of `sel` sits on a callout's close fence line, the only
 *  part of the selection the build reads (via calloutBlockAt). */
function onCloseFence(doc: Text, sel: SelectionRange): boolean {
  const anchor = doc.lineAt(sel.anchor).number;
  const head = doc.lineAt(sel.head).number;
  return scanCallouts(doc).some((r) => r.closeLine === anchor || r.closeLine === head);
}

export const tableField = StateField.define<DecorationSet>({
  create(state) {
    return buildTableDecorations(state);
  },
  update(decos, tr) {
    // Also rebuild when background parsing advances the tree: in a long doc a
    // Table below the first window is parsed later, and would otherwise stay
    // raw source until the next edit.
    if (tr.docChanged || syntaxTree(tr.state) !== syntaxTree(tr.startState)) {
      return buildTableDecorations(tr.state);
    }
    // Selection moves matter only at a close fence (hideTo). scanCallouts is
    // cached per Text, so the check is cheap.
    if (!tr.selection) return decos;
    const doc = tr.state.doc;
    if (!onCloseFence(doc, tr.startState.selection.main) && !onCloseFence(doc, tr.selection.main)) {
      return decos;
    }
    return buildTableDecorations(tr.state);
  },
  provide: (f) => [
    EditorView.decorations.from(f),
    // Atomic: arrows and clicks must never drop the CM6 caret into the source.
    EditorView.atomicRanges.of((view) => view.state.field(f, false) ?? Decoration.none),
  ],
});

export function tablePlugin(): Extension {
  return [tableField, tableArrowKeymap];
}

// ---- Table-aware vertical navigation ----
// CM6's moveVertically can jump a tall atomic table plus the text around it in
// one press. Two overrides, otherwise the default (wrapped prose untouched):
//  1. The adjacent line is a table: cross it as one line.
//  2. The default move would skip a whole table: step one logical line.

interface TableLines {
  startLine: number;
  endLine: number;
}

/** If `lineNumber` falls inside a GFM Table node, return its line span. */
function tableSpanAtLine(state: EditorState, lineNumber: number): TableLines | null {
  if (lineNumber < 1 || lineNumber > state.doc.lines) return null;
  const line = state.doc.line(lineNumber);
  const tree = syntaxTree(state);
  let node: ReturnType<typeof tree.resolveInner> | null = tree.resolveInner(line.from, 1);
  while (node && node.name !== 'Table') node = node.parent;
  if (!node) return null;
  return {
    startLine: state.doc.lineAt(node.from).number,
    endLine: state.doc.lineAt(Math.max(node.from, node.to - 1)).number,
  };
}

/** True if a whole Table node sits strictly between lines `low` and `high`. */
function tableBetween(state: EditorState, low: number, high: number): boolean {
  if (high - low < 2) return false;
  const { doc } = state;
  let found = false;
  syntaxTree(state).iterate({
    from: doc.line(low + 1).from,
    to: doc.line(high - 1).to,
    enter(node) {
      if (found) return false;
      if (node.name !== 'Table') return;
      const ts = doc.lineAt(node.from).number;
      const te = doc.lineAt(Math.max(node.from, node.to - 1)).number;
      if (ts > low && te < high) found = true;
      return false;
    },
  });
  return found;
}

function applyHead(view: EditorView, head: number, extend: boolean): boolean {
  // Keep the goal-column session alive across the crossing (R-V2 in
  // docs/specs/2026-08-23-caret-and-reveal-semantics.md), or the next press
  // re-captures the goal at the col-0 landing.
  if (!extend) {
    dispatchVerticalStop(view, head);
    return true;
  }
  // The same bookkeeping as dispatchVerticalStop, for an extended selection.
  const sel = view.state.selection.main;
  verticalGoalX(view);
  view.dispatch({
    selection: EditorSelection.range(sel.anchor, head),
    scrollIntoView: true,
    userEvent: 'select',
  });
  recordVerticalLanding(view, head);
  return true;
}

function moveAcrossTable(view: EditorView, forward: boolean, extend: boolean): boolean {
  const { state } = view;
  const tables = state.field(tableField, false);
  if (!tables || tables.size === 0) return false;

  const sel = state.selection.main;
  const headLine = state.doc.lineAt(sel.head).number;
  const lines = state.doc.lines;

  // (1)
  const adjacent = forward ? headLine + 1 : headLine - 1;
  const span = tableSpanAtLine(state, adjacent);
  if (span) {
    if (forward) {
      const t = span.endLine + 1;
      return applyHead(view, t <= lines ? state.doc.line(t).from : state.doc.length, extend);
    }
    const t = span.startLine - 1;
    return applyHead(view, t >= 1 ? state.doc.line(t).to : 0, extend);
  }

  if (forward ? headLine >= lines : headLine <= 1) return false;

  // (2) Predict the default motion without dispatching.
  let defLine: number;
  try {
    const def = view.moveVertically(sel, forward);
    defLine = state.doc.lineAt(def.head).number;
  } catch {
    return false; // no layout (tests)
  }
  const overshot = forward
    ? tableBetween(state, headLine, defLine)
    : tableBetween(state, defLine, headLine);
  if (!overshot) return false;

  const targetLine = forward ? headLine + 1 : headLine - 1;
  return applyHead(view, sameColumnOnLine(state, sel.head, targetLine), extend);
}

const tableArrowKeymap: Extension = Prec.high(
  keymap.of([
    { key: 'ArrowUp', run: (v) => moveAcrossTable(v, false, false) },
    { key: 'ArrowDown', run: (v) => moveAcrossTable(v, true, false) },
    { key: 'Shift-ArrowUp', run: (v) => moveAcrossTable(v, false, true) },
    { key: 'Shift-ArrowDown', run: (v) => moveAcrossTable(v, true, true) },
  ]),
);

export const _testing = { tableSpanAtLine, tableBetween, moveAcrossTable };
