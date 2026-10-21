import { describe, it, expect } from 'vitest';
import {
  type TexChange,
  type TexTable,
  cellEdit,
  cellTextToSource,
  deleteColumnEdit,
  deleteRowEdit,
  expandSpecRepeats,
  insertColumnEdit,
  insertRowEdit,
  parseColumnSpec,
  scanTexTables,
  setAlignEdit,
  toggleRuleBelowEdit,
} from '../src/editor/tex-table-model';

const RESULTS = String.raw`\begin{center}
\resizebox{\textwidth}{!}{
\begin{tabular}{lcccc}
\toprule
 & $\zeta_{c}$ & $\zeta_{a}$ & $\zeta_{ra}$ & Top 1\%\\
\midrule
Data (adjusted PSID) & 3.06 & 1.38 & 1.20 & 35\%\\
\midrule
(1) Homothetic, homogeneous returns & 3.04 & 2.42 & 2.42 & 9\%\\
(2) Homothetic, type dependence & 2.65 & 1.32 & 1.02 & 29\%\\
\bottomrule
\end{tabular}}
\end{center}`;

function apply(text: string, changes: TexChange[]): string {
  let out = text;
  for (const c of [...changes].sort((a, b) => b.from - a.from)) {
    out = out.slice(0, c.from) + c.insert + out.slice(c.to);
  }
  return out;
}

function only(text: string): TexTable {
  const tables = scanTexTables(text);
  expect(tables).toHaveLength(1);
  return tables[0];
}

function cellTexts(text: string, t: TexTable): string[][] {
  return t.rows.map((r) => r.cells.map((c) => text.slice(c.editFrom, c.editTo)));
}

describe('scanTexTables', () => {
  it('reads the booktabs results table', () => {
    const t = only(RESULTS);
    expect(t.env).toBe('tabular');
    expect(RESULTS.slice(t.specFrom, t.specTo)).toBe('lcccc');
    expect(t.ncols).toBe(5);
    expect(t.spec.columns.map((c) => c.align)).toEqual(['left', 'center', 'center', 'center', 'center']);
    expect(cellTexts(RESULTS, t)).toEqual([
      ['', '$\\zeta_{c}$', '$\\zeta_{a}$', '$\\zeta_{ra}$', 'Top 1\\%'],
      ['Data (adjusted PSID)', '3.06', '1.38', '1.20', '35\\%'],
      ['(1) Homothetic, homogeneous returns', '3.04', '2.42', '2.42', '9\\%'],
      ['(2) Homothetic, type dependence', '2.65', '1.32', '1.02', '29\\%'],
    ]);
    expect(t.rows[0].rules).toEqual([{ weight: 'heavy', from: 0, to: Infinity }]);
    expect(t.rows[1].rules).toEqual([{ weight: 'thin', from: 0, to: Infinity }]);
    expect(t.rows[3].rules).toEqual([]);
    expect(t.trailingRules).toEqual([{ weight: 'heavy', from: 0, to: Infinity }]);
    // `}` after `\end{tabular}` is the resizebox's, outside the table.
    expect(RESULTS.slice(t.to, t.to + 1)).toBe('}');
  });

  it('keeps nested braces, environments and escaped & in one cell', () => {
    const src = String.raw`\begin{tabular}{ll}
\textbf{a & b} & \begin{tabular}{c} x \\ y \end{tabular} \\
R\&D & $\begin{matrix} 1 & 2 \end{matrix}$ \\
\end{tabular}`;
    const t = only(src);
    expect(cellTexts(src, t)).toEqual([
      ['\\textbf{a & b}', '\\begin{tabular}{c} x \\\\ y \\end{tabular}'],
      ['R\\&D', '$\\begin{matrix} 1 & 2 \\end{matrix}$'],
    ]);
  });

  it('reads \\multicolumn spans, \\cmidrule ranges and \\\\[len]', () => {
    const src = String.raw`\begin{tabular}{lrr}
\toprule
& \multicolumn{2}{c}{Panel A} \\[2pt]
\cmidrule(lr){2-3}
x & 1 & 2 \\
\end{tabular}`;
    const t = only(src);
    const head = t.rows[0];
    expect(head.cells[1]).toMatchObject({ span: 2, col: 1, align: 'center' });
    expect(src.slice(head.cells[1].editFrom, head.cells[1].editTo)).toBe('Panel A');
    expect(src.slice(head.endFrom, head.endTo)).toBe('\\\\[2pt]');
    expect(t.rows[1].rules).toEqual([{ weight: 'thin', from: 1, to: 2 }]);
  });

  it('skips comments, verbatim and malformed tables', () => {
    expect(scanTexTables('% \\begin{tabular}{l} a \\end{tabular}')).toEqual([]);
    expect(scanTexTables('\\begin{verbatim}\n\\begin{tabular}{l} a \\end{tabular}\n\\end{verbatim}')).toEqual([]);
    // Unbalanced brace: left as source rather than mis-split.
    expect(scanTexTables('\\begin{tabular}{l} \\textbf{a \\\\ \\end{tabular}')).toEqual([]);
    expect(scanTexTables('\\begin{tabular}{l} a \\\\')).toEqual([]);
  });

  it('a % comment does not hide the cell delimiters after it', () => {
    const src = 'Start\n\\begin{tabular}{ll}\na & b % note & not a cell\n\\\\\n\\end{tabular}';
    const t = only(src);
    expect(cellTexts(src, t)).toEqual([['a', 'b % note & not a cell']]);
  });

  it('reads tabularx, tabular*, longtable and tblr arguments', () => {
    const x = only('\\begin{tabularx}{\\textwidth}{lX>{\\centering\\arraybackslash}X} a & b & c \\\\ \\end{tabularx}');
    expect(x.spec.columns.map((c) => c.align)).toEqual(['left', 'left', 'center']);
    const star = only('\\begin{tabular*}{\\linewidth}{@{\\extracolsep{\\fill}}rc} 1 & 2 \\\\ \\end{tabular*}');
    expect(star.spec.columns.map((c) => c.align)).toEqual(['right', 'center']);
    const long = only('\\begin{longtable}[c]{|l|r|}\n\\hline a & b \\\\ \\endhead\n c & d \\\\\n\\end{longtable}');
    expect(long.spec.vrules).toEqual([1, 1, 1]);
    expect(long.rows.map((r) => r.cells.length)).toEqual([2, 2]);
    const tblr = only('\\begin{tblr}{colspec={Q[l]Q[r]}, hlines} a & b \\\\ \\end{tblr}');
    expect(tblr.spec.columns.map((c) => c.align)).toEqual(['left', 'right']);
    expect(tblr.allHLines).toBe(true);
  });

  it('expands *{n}{…} repeats in the spec', () => {
    expect(expandSpecRepeats('l*{3}{c}|r')).toBe('lccc|r');
    expect(parseColumnSpec('l*{3}{c}').columns).toHaveLength(4);
    expect(only('\\begin{tabular}{l*{2}{r}} a & 1 & 2 \\\\ \\end{tabular}').ncols).toBe(3);
  });
});

describe('cell edits', () => {
  it('rewrites only the edited cell', () => {
    const t = only(RESULTS);
    const change = cellEdit(RESULTS, t.rows[1].cells[1], '3.10');
    const out = apply(RESULTS, [change!]);
    expect(out).toBe(RESULTS.replace('Data (adjusted PSID) & 3.06', 'Data (adjusted PSID) & 3.10'));
  });

  it('escapes a typed % and top-level &', () => {
    expect(cellTextToSource('35% R&D $a&b$', '')).toBe('35\\% R\\&D $a&b$');
    expect(cellTextToSource('35\\%', '')).toBe('35\\%');
    // A cell that already has a comment is raw source: verbatim.
    expect(cellTextToSource('x % c', 'y % c')).toBe('x % c');
  });

  it('pads text typed into an empty cell between tight delimiters', () => {
    const src = '\\begin{tabular}{lll}\na &  & c \\\\\n\\end{tabular}';
    const t = only(src);
    const out = apply(src, [cellEdit(src, t.rows[0].cells[1], 'b')!]);
    expect(out).toContain('a & b & c');
    const tight = '\\begin{tabular}{ll}\na&\\\\\n\\end{tabular}';
    const t2 = only(tight);
    expect(apply(tight, [cellEdit(tight, t2.rows[0].cells[1], 'b')!])).toContain('a& b \\\\');
  });

  it('edits the content argument of \\multicolumn', () => {
    const src = '\\begin{tabular}{lrr}\n& \\multicolumn{2}{c}{Panel A} \\\\\n\\end{tabular}';
    const t = only(src);
    const out = apply(src, [cellEdit(src, t.rows[0].cells[1], 'Panel B')!]);
    expect(out).toContain('\\multicolumn{2}{c}{Panel B}');
  });
});

describe('structural edits', () => {
  it('inserts a row below, matching column count and indent', () => {
    const t = only(RESULTS);
    const out = apply(RESULTS, insertRowEdit(RESULTS, t, 1, 'below'));
    expect(out).toContain('Data (adjusted PSID) & 3.06 & 1.38 & 1.20 & 35\\%\\\\\n& & & & \\\\\n\\midrule');
    expect(only(out).rows).toHaveLength(5);
  });

  it('inserts a row above, under the row\'s own rule', () => {
    const t = only(RESULTS);
    const out = apply(RESULTS, insertRowEdit(RESULTS, t, 1, 'above'));
    expect(out).toContain('\\midrule\n& & & & \\\\\nData');
  });

  it('deletes a row and keeps the rule above it', () => {
    const t = only(RESULTS);
    const out = apply(RESULTS, deleteRowEdit(RESULTS, t, 1));
    expect(out).not.toContain('Data (adjusted');
    expect(out).toContain('Top 1\\%\\\\\n\\midrule\n\\midrule\n(1)');
  });

  it('inserts and deletes a column in the spec and every row', () => {
    const t = only(RESULTS);
    const ins = apply(RESULTS, insertColumnEdit(RESULTS, t, 1));
    const ti = only(ins);
    // The new column copies the alignment of the one it pushes right.
    expect(ins.slice(ti.specFrom, ti.specTo)).toBe('lccccc');
    expect(ti.rows.every((r) => r.cells.length === 6)).toBe(true);
    expect(ti.rows[1].cells[1].from).toBe(ti.rows[1].cells[1].to); // new cell empty
    const del = apply(ins, deleteColumnEdit(ins, ti, 1));
    expect(del).toBe(RESULTS);
  });

  it('widens and narrows a \\multicolumn spanning the column', () => {
    const src = '\\begin{tabular}{lrr}\n& \\multicolumn{2}{c}{A} \\\\\nx & 1 & 2 \\\\\n\\end{tabular}';
    const t = only(src);
    const ins = apply(src, insertColumnEdit(src, t, 2));
    expect(ins).toContain('\\multicolumn{3}{c}{A}');
    expect(ins).toContain('x & 1 & & 2');
    const del = apply(src, deleteColumnEdit(src, t, 2));
    expect(del).toContain('\\multicolumn{1}{c}{A}');
    expect(del).toContain('x & 1 \\\\');
  });

  it('drops one side of the vertical rules with a deleted column', () => {
    const src = '\\begin{tabular}{|l|c|}\na & b \\\\\n\\end{tabular}';
    const out = apply(src, deleteColumnEdit(src, only(src), 1));
    expect(out).toContain('{|l|}');
    expect(out).toContain('a \\\\');
  });

  it('sets alignment only on plain l/c/r columns', () => {
    const t = only(RESULTS);
    expect(apply(RESULTS, setAlignEdit(RESULTS, t, 2, 'right'))).toContain('{lcrcc}');
    const p = '\\begin{tabular}{p{2cm}c} a & b \\\\ \\end{tabular}';
    expect(setAlignEdit(p, only(p), 0, 'right')).toEqual([]);
    const rep = '\\begin{tabular}{l*{2}{c}} a & b & c \\\\ \\end{tabular}';
    expect(apply(rep, setAlignEdit(rep, only(rep), 2, 'right'))).toContain('{lcr}');
  });

  it('toggles a rule under a row', () => {
    const t = only(RESULTS);
    // Row 2 has none below it: add a booktabs midrule.
    const added = apply(RESULTS, toggleRuleBelowEdit(RESULTS, t, 2));
    expect(added).toContain('9\\%\\\\\n\\midrule\n(2)');
    // Row 0 has one: remove it.
    const removed = apply(RESULTS, toggleRuleBelowEdit(RESULTS, t, 0));
    expect(removed).toContain('Top 1\\%\\\\\nData');
    const plain = '\\begin{tabular}{ll}\na & b \\\\\nc & d \\\\\n\\end{tabular}';
    expect(apply(plain, toggleRuleBelowEdit(plain, only(plain), 0))).toContain('a & b \\\\\n\\hline\nc');
  });
});
