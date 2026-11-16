import { describe, expect, it } from 'vitest';
import { wordHunks } from '../src/utils/word-diff';

/** Apply hunks to `a`: whatever the diff chose, it must rebuild `b`. */
function apply(a: string, b: string): string {
  let out = '';
  let at = 0;
  for (const h of wordHunks(a, b)) {
    out += a.slice(at, h.fromA) + b.slice(h.fromB, h.toB);
    at = h.toA;
  }
  return out + a.slice(at);
}

describe('wordHunks', () => {
  it('is empty for equal texts', () => {
    expect(wordHunks('same\ntext', 'same\ntext')).toEqual([]);
  });

  it('marks a whole word, not the differing letters', () => {
    const a = 'The factor is fixed here.';
    const b = 'The factor is fast here.';
    const [h, ...rest] = wordHunks(a, b);
    expect(rest).toEqual([]);
    expect(a.slice(h.fromA, h.toA)).toBe('fixed');
    expect(b.slice(h.fromB, h.toB)).toBe('fast');
  });

  it('keeps two far apart edits as two hunks', () => {
    const lines = Array.from({ length: 50 }, (_, i) => `line ${i}`);
    const edited = [...lines];
    edited[5] = 'line five';
    edited[40] = 'line forty';
    expect(wordHunks(lines.join('\n'), edited.join('\n'))).toHaveLength(2);
  });

  it('reports a pure insertion and a pure deletion', () => {
    const a = 'one\nthree\n';
    const b = 'one\ntwo\nthree\n';
    expect(wordHunks(a, b)).toEqual([{ fromA: 4, toA: 4, fromB: 4, toB: 8 }]);
    expect(wordHunks(b, a)).toEqual([{ fromA: 4, toA: 8, fromB: 4, toB: 4 }]);
  });

  it('joins words changed either side of one space', () => {
    expect(wordHunks('a one two b', 'a uno dos b')).toHaveLength(1);
  });

  it('makes a rewritten sentence one hunk despite shared words', () => {
    const a = 'The household values consumption with log utility and a factor $\\beta$.\n';
    const b = 'Utility is logarithmic, so the household maximises $\\log c_1 + \\beta \\log c_2$.\n';
    expect(wordHunks(a, b)).toHaveLength(1);
  });

  it('keeps two small edits apart when the words between are longer', () => {
    expect(wordHunks('the fox ran across the wide open road', 'the cat ran across the wide open lane')).toHaveLength(2);
  });

  it('does not join across a kept line', () => {
    expect(wordHunks('one\nsame\ntwo\n', 'uno words\nsame\ndos words\n')).toHaveLength(2);
  });

  it('never splits a surrogate pair', () => {
    const a = 'x 😀 y';
    const b = 'x 😁 y';
    const [h] = wordHunks(a, b);
    expect(b.slice(h.fromB, h.toB)).toBe('😁');
  });

  it('rebuilds the target for assorted edits', () => {
    const cases: [string, string][] = [
      ['', 'new'],
      ['old', ''],
      ['a\nb\nc', 'a\nc\nb'],
      ['no newline', 'no newline\n'],
      ['$x^2$ and text\n\n\\[ y \\]\n', '$x^3$ and more text\n\\[ y \\]\n\nend'],
      ['a b c d e', 'e d c b a'],
    ];
    for (const [a, b] of cases) expect(apply(a, b)).toBe(b);
  });

  it('degrades to a coarse hunk past the cost cap, still correct', () => {
    const a = Array.from({ length: 6000 }, (_, i) => `a${i}`).join('\n');
    const b = Array.from({ length: 6000 }, (_, i) => `b${i}`).join('\n');
    expect(apply(a, b)).toBe(b);
  });
});
