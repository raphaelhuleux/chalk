// texTableField: every well-formed tabular-family environment (tabular,
// tabular*, tabularx, tabulary, longtable, tblr) becomes a block-replace
// TexTableWidget over its whole `\begin`…`\end` lines. Atomic, like the GFM
// table: the CM6 caret never lands in the source; editing happens in the
// widget's cells. The toolbar's `{ }` reveals one table's source until the
// caret leaves it. Tables inside math (`$\begin{tabular}…$`) stay source.

import { Decoration, DecorationSet, EditorView } from '@codemirror/view';
import {
  EditorState,
  Extension,
  RangeSetBuilder,
  SelectionRange,
  StateField,
  Text,
} from '@codemirror/state';
import { KaTeXCache } from '../utils/katex-cache';
import { docText } from '../utils/doc-text';
import { calloutBlockAt } from './callout-core';
import { regionAt } from './display-math-core';
import { scanTexCallouts } from './tex-callout-plugin';
import { frameBlockAt } from './tex-frame-plugin';
import { mathRegionsOf } from './tex-math-incremental';
import { texTablesOf } from './tex-table-model';
import { TexTableWidget, revealTexTable } from './tex-table-widget';
import { blockCrossingKeymap, type BlockSpans } from './table-field';

interface Range {
  from: number;
  to: number;
}

interface TexTableState {
  decos: DecorationSet;
  /** Line range of the table whose source the toolbar revealed. */
  revealed: Range | null;
}

// One cache for every table cell: cells repeat a lot (`$\checkmark$`).
const cache = new KaTeXCache();

function build(state: EditorState, revealed: Range | null): DecorationSet {
  const { doc } = state;
  const tables = texTablesOf(doc);
  if (tables.length === 0) return Decoration.none;
  const text = docText(doc);
  const math = mathRegionsOf(state);
  const builder = new RangeSetBuilder<Decoration>();
  let prevEnd = -1;
  for (const t of tables) {
    if (regionAt(math, t.from)) continue;
    const begin = doc.lineAt(t.from);
    const end = doc.lineAt(t.to);
    // Two tables sharing a line can't both own it whole.
    if (begin.from <= prevEnd) continue;
    if (revealed && begin.from < revealed.to && end.to > revealed.from) continue;
    const callout = calloutBlockAt(doc, scanTexCallouts, begin.from, end.to, state.selection.main);
    const widget = new TexTableWidget(
      t,
      text.slice(t.from, t.to),
      text.slice(begin.from, t.from).trim(),
      text.slice(t.to, end.to).trim(),
      cache,
      callout ? { type: callout.type, bottom: callout.bottom } : null,
      frameBlockAt(doc, begin.from, end.to),
    );
    const to = callout?.hideTo ?? end.to;
    builder.add(begin.from, to, Decoration.replace({ widget, block: true }));
    prevEnd = to;
  }
  return builder.finish();
}

/** Whether either end of `sel` sits on a tex callout's close fence line, the
 *  only selection the build reads (via calloutBlockAt). */
function onCloseFence(doc: Text, sel: SelectionRange): boolean {
  const anchor = doc.lineAt(sel.anchor).number;
  const head = doc.lineAt(sel.head).number;
  return scanTexCallouts(doc).some((r) => r.closeLine === anchor || r.closeLine === head);
}

export const texTableField = StateField.define<TexTableState>({
  create(state) {
    return { decos: build(state, null), revealed: null };
  },
  update(value, tr) {
    let revealed = value.revealed;
    if (revealed && tr.docChanged) {
      revealed = { from: tr.changes.mapPos(revealed.from, -1), to: tr.changes.mapPos(revealed.to, 1) };
    }
    for (const e of tr.effects) if (e.is(revealTexTable)) revealed = e.value;
    if (revealed) {
      const sel = tr.state.selection.main;
      if (sel.from < revealed.from || sel.to > revealed.to) revealed = null;
    }
    const revealChanged =
      revealed?.from !== value.revealed?.from || revealed?.to !== value.revealed?.to;
    if (tr.docChanged || revealChanged) {
      return { decos: build(tr.state, revealed), revealed };
    }
    if (
      tr.selection &&
      (onCloseFence(tr.state.doc, tr.startState.selection.main) ||
        onCloseFence(tr.state.doc, tr.selection.main))
    ) {
      return { decos: build(tr.state, revealed), revealed };
    }
    return value;
  },
  provide: (f) => [
    EditorView.decorations.from(f, (v) => v.decos),
    // Atomic: arrows and clicks must never drop the CM6 caret into the source.
    EditorView.atomicRanges.of((view) => view.state.field(f, false)?.decos ?? Decoration.none),
  ],
});

function lineSpans(state: EditorState): Array<{ startLine: number; endLine: number }> {
  const decos = state.field(texTableField, false)?.decos;
  const out: Array<{ startLine: number; endLine: number }> = [];
  decos?.between(0, state.doc.length, (from, to) => {
    out.push({
      startLine: state.doc.lineAt(from).number,
      endLine: state.doc.lineAt(Math.max(from, to - 1)).number,
    });
  });
  return out;
}

const texSpans: BlockSpans = {
  any: (state) => (state.field(texTableField, false)?.decos.size ?? 0) > 0,
  spanAtLine: (state, n) => lineSpans(state).find((s) => s.startLine <= n && n <= s.endLine) ?? null,
  between: (state, low, high) =>
    lineSpans(state).some((s) => s.startLine > low && s.endLine < high),
};

// Module-level, so the Preview and Mixed sets share one instance and a mode
// switch keeps the field's value.
const texTableExtension: Extension = [texTableField, blockCrossingKeymap(texSpans)];

export function texTablePlugin(): Extension {
  return texTableExtension;
}
