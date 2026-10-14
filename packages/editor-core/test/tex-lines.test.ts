import { describe, it, expect } from 'vitest';
import { commentStart, uncommented } from '../src/editor/tex-lines';

describe('commentStart', () => {
  it('finds the first unescaped %', () => {
    expect(commentStart('a % b % c')).toBe(2);
    expect(commentStart('% at start')).toBe(0);
    expect(commentStart('no comment')).toBe(-1);
  });

  it('skips an escaped \\%', () => {
    expect(commentStart('100\\% sure')).toBe(-1);
    expect(commentStart('100\\% sure % note')).toBe(11);
  });

  it('reads \\\\% as an escaped backslash, then a comment', () => {
    expect(commentStart('row\\\\% note')).toBe(5);
    expect(uncommented('\\begin{frame}{T}\\\\% note')).toBe('\\begin{frame}{T}\\\\');
  });
});
