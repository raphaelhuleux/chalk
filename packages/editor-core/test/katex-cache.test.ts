import { describe, it, expect, vi } from 'vitest';
import { KaTeXCache, countSourceEquationNumbers } from '../src/utils/katex-cache';
import { countEquationNumbers } from './helpers/katex';

/**
 * KaTeX lacks LaTeX's counter/cross-reference machinery, so document-bookkeeping
 * commands must be swallowed rather than fail the whole render (returning null →
 * raw source fallback).
 */
describe('KaTeXCache: unsupported-command tolerance', () => {
  const cache = new KaTeXCache();

  it('renders an align block with \\tag and \\setcounter (the reported bug)', () => {
    const src = [
      '\\begin{align}',
      ' & a^{r} \\cdot a^{s}=a^{r+s} \\tag{Multiplication rule} \\\\',
      ' & (ab)^n=a^n b^n \\setcounter{equation}{2} \\\\',
      ' & a^0=1',
      '\\end{align}',
    ].join('\n');
    expect(cache.render(src, true)).not.toBeNull();
  });

  it('swallows the other counter commands', () => {
    expect(cache.render('a=b \\addtocounter{equation}{1}', true)).not.toBeNull();
    expect(cache.render('a=b \\stepcounter{equation}', true)).not.toBeNull();
    expect(cache.render('a=b \\refstepcounter{equation}', true)).not.toBeNull();
  });

  it('still swallows \\label', () => {
    expect(cache.render('A = b \\label{eq:1}', true)).not.toBeNull();
  });

  it('still returns null for a genuinely invalid expression', () => {
    expect(cache.render('\\frac{1}', true)).toBeNull();
  });
});

describe('KaTeXCache: renders are independent', () => {
  it('does not leak a \\gdef into later renders', () => {
    const cache = new KaTeXCache();
    expect(cache.render('\\gdef\\leaked{x} a', true)).not.toBeNull();
    // Undefined here, in this cache and in any other.
    expect(cache.render('\\leaked', true)).toBeNull();
    expect(new KaTeXCache().render('\\leaked', false)).toBeNull();
  });
});

describe('KaTeXCache: pathological input never throws (audit C-2)', () => {
  it('returns null for stack-overflow-deep nesting instead of rethrowing', () => {
    const cache = new KaTeXCache();
    // KaTeX throws RangeError (not ParseError) on these — a rethrow inside a
    // CM6 StateField build bricks dispatch for every later transaction.
    const deepFrac = '\\frac{1}{'.repeat(2000) + '2' + '}'.repeat(2000);
    expect(() => cache.render(deepFrac, true)).not.toThrow();
    expect(cache.render(deepFrac, true)).toBeNull();
    const deepBraces = '{'.repeat(10000) + 'x' + '}'.repeat(10000);
    expect(() => cache.render(deepBraces, true)).not.toThrow();
    expect(cache.render(deepBraces, true)).toBeNull();
  });

  it('caches failed renders so invalid input parses only once (audit M-14)', async () => {
    const katex = (await import('katex')).default;
    const spy = vi.spyOn(katex, 'renderToString');
    const cache = new KaTeXCache();
    expect(cache.render('\\frac{1}', true)).toBeNull();
    expect(cache.render('\\frac{1}', true)).toBeNull();
    expect(cache.render('\\frac{1}', true)).toBeNull();
    expect(spy).toHaveBeenCalledTimes(1);
    spy.mockRestore();
  });
});

describe('countSourceEquationNumbers parity with rendered HTML (audit H-9)', () => {
  const render = (tex: string): string | null => {
    const cache = new KaTeXCache();
    return cache.render(tex, true);
  };

  const CASES = [
    '\\begin{equation}a=b\\end{equation}',
    '\\begin{equation*}a=b\\end{equation*}',
    '\\begin{align}x&=1\\\\y&=2\\end{align}',
    '\\begin{align*}x&=1\\\\y&=2\\end{align*}',
    '\\begin{align}x&=1\\notag\\\\y&=2\\end{align}',
    '\\begin{align}x&=1\\nonumber\\\\y&=2\\end{align}',
    '\\begin{equation}a=b\\tag{A}\\end{equation}',
    '\\begin{gather}a=1\\\\b=2\\\\c=3\\end{gather}',
    '\\begin{gather*}a=1\\\\b=2\\end{gather*}',
    '\\begin{align}x&=1\\\\y&=2\\\\\\end{align}', // trailing \\
    '\\begin{equation}\\begin{split}a&=b\\\\&=c\\end{split}\\end{equation}', // nested rows don't count
    '\\begin{align}\\begin{cases}1\\\\2\\end{cases}&=x\\\\y&=2\\end{align}',
    '\\begin{equation}a=\\substack{1\\\\2}\\end{equation}', // \\ inside braces
    'a=b', // plain display math: no number
    '\\begin{equation}E=mc^2\\end{equation}\\quad\\begin{align}a&=1\\\\b&=2\\end{align}', // two envs
  ];

  it.each(CASES)('matches the HTML count for %s', (src) => {
    const html = render(src);
    // Every case here must actually render — a null would make the parity
    // assertion vacuous.
    expect(html).not.toBeNull();
    expect(countSourceEquationNumbers(src)).toBe(countEquationNumbers(html));
  });
});

describe('countSourceEquationNumbers memoization', () => {
  it('parses a given source at most once (builders call it per region per rebuild)', async () => {
    const { countSourceEquationNumbers, __sourceCountParses } = await import(
      '../src/utils/katex-cache'
    );
    const src = '\\begin{align} q_0 &= r_0 \\\\ s_0 &= t_0 \\end{align}'; // unique to this test
    const before = __sourceCountParses();
    const n1 = countSourceEquationNumbers(src);
    const n2 = countSourceEquationNumbers(src);
    expect(n1).toBe(2);
    expect(n2).toBe(2);
    expect(__sourceCountParses() - before).toBe(1);
  });
});
