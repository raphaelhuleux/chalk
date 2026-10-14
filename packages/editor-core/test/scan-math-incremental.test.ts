import { describe, it, expect } from 'vitest';
import { ChangeSet, Text } from '@codemirror/state';
import { type MathRegion } from '../src/editor/tex-math';
import { fullMathScan, rescanMathRegions } from '../src/editor/tex-math-incremental';

/**
 * The incremental math scan must be indistinguishable from the full one.
 *
 * `scanMathRegions` is 18-20% of tex keystroke script time in the bundle
 * profile (2026-08-26) because it re-reads the whole document on every
 * document change. The incremental form reuses the regions a change cannot
 * have touched, which is only sound if it agrees with the full scan on EVERY
 * edit, not on the ones someone thought to enumerate. So the contract is
 * pinned by a differential property test over random edit sequences: any
 * disagreement is a rendering corruption that would show as math silently
 * failing to render, or prose being swallowed into a widget.
 */

/** Document text with every construct the scanner knows, so random edits land
 *  on delimiters, comments, escapes and environment names alike. */
function seedText(): string {
  const lines: string[] = [];
  for (let i = 0; i < 60; i++) {
    lines.push(`Prose line ${i} with words.`);
    if (i % 3 === 0) lines.push(`Inline $a_{${i}} + b^{${i}}$ mid sentence.`);
    if (i % 5 === 0) lines.push(`Paren \\(x_{${i}}\\) and a \\$ literal dollar.`);
    if (i % 7 === 0) lines.push('\\[', `  \\int_0^{${i}} f = ${i}`, '\\]');
    if (i % 11 === 0) lines.push('\\begin{align}', `  y &= ${i} x \\\\`, '\\end{align}');
    if (i % 13 === 0) lines.push(`% a comment with $fake math$ inside`);
    if (i % 17 === 0) lines.push(`Display $$z_{${i}}$$ inline-style.`);
  }
  return lines.join('\n');
}

/** Deterministic PRNG so a failure is reproducible from its seed alone. */
function rng(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 0x100000000;
  };
}

/** Edit fragments chosen to break delimiter pairing, not just prose. */
const INSERTS = [
  'x',
  ' ',
  '\n',
  '$',
  '$$',
  '\\[',
  '\\]',
  '\\(',
  '\\)',
  '%',
  '\\begin{align}',
  '\\end{align}',
  '\\',
  '{',
  '}',
  'the quick brown fox',
];

function normalize(regions: readonly MathRegion[]): string {
  return JSON.stringify(
    regions.map((r) => [r.from, r.to, r.display, r.content]),
  );
}

describe('rescanMathRegions — agrees with the full scan', () => {
  it('matches scanMathRegions after every edit in 150 random sequences', () => {
    for (let seed = 1; seed <= 150; seed++) {
      const rand = rng(seed);
      let doc = Text.of(seedText().split('\n'));
      let scan = fullMathScan(doc);

      for (let step = 0; step < 25; step++) {
        const len = doc.length;
        const from = Math.floor(rand() * (len + 1));
        // Mostly insertions, sometimes a deletion of a short span.
        const deleting = rand() < 0.35;
        const to = deleting ? Math.min(len, from + 1 + Math.floor(rand() * 12)) : from;
        const insert = deleting && rand() < 0.5
          ? ''
          : INSERTS[Math.floor(rand() * INSERTS.length)];

        const changes = ChangeSet.of([{ from, to, insert }], len);
        const newDoc = changes.apply(doc);

        const incremental = rescanMathRegions(doc, newDoc, changes, scan);
        const full = fullMathScan(newDoc);

        expect(
          normalize(incremental.regions),
          `seed ${seed} step ${step}: {from:${from},to:${to},insert:${JSON.stringify(insert)}}`,
        ).toBe(normalize(full.regions));
        expect(
          incremental.hasStray,
          `seed ${seed} step ${step}: stray flag`,
        ).toBe(full.hasStray);

        doc = newDoc;
        scan = incremental;
      }
    }
  });

  it('matches the full scan for a multi-range change', () => {
    // CM6 hands a StateField one ChangeSet per transaction, and a snippet
    // expansion or a multi-cursor edit puts several ranges in it. The helper
    // must not assume a single splice.
    const doc = Text.of(seedText().split('\n'));
    const len = doc.length;
    const changes = ChangeSet.of(
      [
        { from: 10, to: 10, insert: '$' },
        { from: 400, to: 405, insert: '\\[' },
        { from: 900, to: 900, insert: '\\end{align}' },
      ],
      len,
    );
    const newDoc = changes.apply(doc);
    const incremental = rescanMathRegions(doc, newDoc, changes, fullMathScan(doc));
    expect(normalize(incremental.regions)).toBe(normalize(fullMathScan(newDoc).regions));
  });

  it('reuses regions far from the edit instead of rescanning them', async () => {
    // The point of the exercise: an edit in the tail must not re-derive the
    // head. Measured as characters the incremental scanner actually looked at.
    const { __rescanCharCount, __resetRescanCharCount } = await import(
      '../src/editor/tex-math-incremental'
    );
    const doc = Text.of(seedText().split('\n'));
    const scan = fullMathScan(doc);
    const at = doc.length - 20;
    const changes = ChangeSet.of([{ from: at, to: at, insert: 'x' }], doc.length);
    const newDoc = changes.apply(doc);

    __resetRescanCharCount();
    rescanMathRegions(doc, newDoc, changes, scan);
    expect(__rescanCharCount()).toBeLessThan(doc.length / 4);
  });
});
