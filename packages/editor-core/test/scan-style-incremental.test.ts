import { afterEach, describe, it, expect, vi } from 'vitest';
import { deleteCharBackward } from '@codemirror/commands';
import { ChangeSet, Text } from '@codemirror/state';
import { texStyleRegionsField } from '../src/editor/tex-decorations';
import { fullStyleScan, rescanStyleRegions, type TexStyleRegion } from '../src/editor/tex-style-incremental';
import { fullMathScan } from '../src/editor/tex-math-incremental';
import { destroyViews, texView } from './helpers/views';

afterEach(destroyViews);

/**
 * The incremental style scan must be indistinguishable from the full one.
 *
 * `scanTexStyleRegions` became 40% of tex keystroke script time once the math
 * scan stopped re-reading the document (2026-08-26), for the same reason: it
 * re-derives every `\section{…}`, `\textbf{…}`, `\ref{…}` in the file on every
 * change. The incremental form reuses the ones an edit cannot have touched.
 *
 * Same contract as the math twin, and for the same reason: these regions feed
 * live styling AND the hierarchical section numbering, so a disagreement shows
 * up as headings losing their colour or renumbering themselves as you type.
 * Random edit sequences, compared against the full scan after every one.
 */

function seedText(): string {
  const lines: string[] = [];
  for (let i = 0; i < 50; i++) {
    if (i % 6 === 0) lines.push(`\\section{Section ${i}}`);
    if (i % 9 === 0) lines.push(`\\subsection{Sub ${i} with \\textbf{bold} inside}`);
    lines.push(`Prose line ${i} with \\emph{emphasis} and \\ref{eq:${i}} in it.`);
    if (i % 4 === 0) lines.push(`A \\href{https://example.com/${i}}{link ${i}} and \\cite{key${i}}.`);
    if (i % 5 === 0) lines.push(`Math $x_{${i}}$ next to \\texttt{code} and \\%.`);
    if (i % 7 === 0) lines.push(`% a comment with \\textbf{not styled} inside`);
    if (i % 11 === 0) lines.push(`\\[ \\alpha_{${i}} = \\textbf{inside math} \\]`);
    if (i % 13 === 0) lines.push(`\\footnote{a note with \\emph{nesting}} trailing.`);
    if (i % 8 === 3) lines.push(`\\textbf{spans`, `  lines ${i}`, `}`);
  }
  return lines.join('\n');
}

function rng(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 0x100000000;
  };
}

const INSERTS = [
  'x',
  ' ',
  '\n',
  '{',
  '}',
  '\\',
  '%',
  '$',
  '\\textbf{',
  '\\section{',
  '\\emph{x}',
  '\\href{a}{b}',
  '\\[',
  '\\]',
  'the quick brown fox',
];

function normalize(regions: readonly TexStyleRegion[]): string {
  return JSON.stringify(
    regions.map((r) => [r.cmdFrom, r.from, r.to, r.kind, r.name, r.starred, r.url ?? null]),
  );
}

/** The scan a consumer would get with no incremental machinery at all. */
function reference(doc: Text) {
  return fullStyleScan(doc, fullMathScan(doc).regions);
}

describe('rescanStyleRegions — agrees with the full scan', () => {
  it('matches scanTexStyleRegions after every edit in 120 random sequences', () => {
    for (let seed = 1; seed <= 120; seed++) {
      const rand = rng(seed);
      let doc = Text.of(seedText().split('\n'));
      let scan = reference(doc);

      for (let step = 0; step < 25; step++) {
        const len = doc.length;
        const from = Math.floor(rand() * (len + 1));
        const deleting = rand() < 0.35;
        const to = deleting ? Math.min(len, from + 1 + Math.floor(rand() * 12)) : from;
        const insert =
          deleting && rand() < 0.5 ? '' : INSERTS[Math.floor(rand() * INSERTS.length)];

        const changes = ChangeSet.of([{ from, to, insert }], len);
        const newDoc = changes.apply(doc);
        const newMath = fullMathScan(newDoc).regions;

        const incremental = rescanStyleRegions(doc, newDoc, changes, scan, fullMathScan(doc).regions, newMath);
        const full = fullStyleScan(newDoc, newMath);

        expect(
          normalize(incremental.regions),
          `seed ${seed} step ${step}: {from:${from},to:${to},insert:${JSON.stringify(insert)}}`,
        ).toBe(normalize(full.regions));

        doc = newDoc;
        scan = incremental;
      }
    }
  });

  it('matches the full scan for a multi-range change', () => {
    const doc = Text.of(seedText().split('\n'));
    const changes = ChangeSet.of(
      [
        { from: 5, to: 5, insert: '\\textbf{' },
        { from: 300, to: 306, insert: '}' },
        { from: 800, to: 800, insert: '\\section{x}' },
      ],
      doc.length,
    );
    const newDoc = changes.apply(doc);
    const newMath = fullMathScan(newDoc).regions;
    const incremental = rescanStyleRegions(doc, newDoc, changes, reference(doc), fullMathScan(doc).regions, newMath);
    expect(normalize(incremental.regions)).toBe(normalize(fullStyleScan(newDoc, newMath).regions));
  });

  it('reuses regions far from the edit instead of rescanning them', async () => {
    const { __styleRescanCharCount, __resetStyleRescanCharCount } = await import(
      '../src/editor/tex-style-incremental'
    );
    const doc = Text.of(seedText().split('\n'));
    const scan = reference(doc);
    const at = doc.length - 30;
    const changes = ChangeSet.of([{ from: at, to: at, insert: 'x' }], doc.length);
    const newDoc = changes.apply(doc);

    __resetStyleRescanCharCount();
    rescanStyleRegions(doc, newDoc, changes, scan, fullMathScan(doc).regions, fullMathScan(newDoc).regions);
    expect(__styleRescanCharCount()).toBeLessThan(doc.length / 4);
  });
});

describe('rescanStyleRegions — a closing brace at a line start', () => {
  // `TexStyleRegion.to` is the index OF the `}`, so a command whose brace
  // opens a line spans that line start; the boundary search must see it.
  const cases: Array<[string, { from: number; to?: number; insert?: string }]> = [
    ['\\footnote{\n  text\n}\nmore', { from: 18, insert: '  ' }],
    ['\\footnote{\n  text\n}\nmore', { from: 18, to: 19 }],
    ['\\footnote{\n  text\n}\nmore', { from: 19, insert: 'x' }],
    ['\\textbf{a\n}\nb', { from: 10, to: 11 }],
    ['\\textbf{a\n}\nb', { from: 9, to: 10 }],
    ['\\textbf{a\n}b', { from: 10, insert: 'x' }],
    ['x\n\\emph{a\n}\n\\textbf{b\n}\ny', { from: 11, insert: ' ' }],
  ];
  for (const [text, change] of cases) {
    it(`${JSON.stringify(text)} ${JSON.stringify(change)}`, () => {
      const doc = Text.of(text.split('\n'));
      const changes = ChangeSet.of(
        [{ from: change.from, to: change.to ?? change.from, insert: change.insert ?? '' }],
        doc.length,
      );
      const newDoc = changes.apply(doc);
      const newMath = fullMathScan(newDoc).regions;
      const incremental = rescanStyleRegions(doc, newDoc, changes, reference(doc), fullMathScan(doc).regions, newMath);
      expect(normalize(incremental.regions)).toBe(normalize(fullStyleScan(newDoc, newMath).regions));
    });
  }

  it('Backspacing a line-leading `}` in a live view raises no plugin error', () => {
    // CM6 catches a plugin's exception and logs it through console.error.
    const errors = vi.spyOn(console, 'error').mockImplementation(() => {});
    const view = texView('\\textbf{a\n}\nb', { cursor: 11 });
    deleteCharBackward(view);
    view.dispatch({ selection: { anchor: view.state.doc.length } });
    expect(errors).not.toHaveBeenCalled();
    errors.mockRestore();
    expect(view.state.doc.toString()).toBe('\\textbf{a\n\nb');
    expect(normalize(view.state.field(texStyleRegionsField).regions)).toBe(
      normalize(reference(view.state.doc).regions),
    );
  });
});
