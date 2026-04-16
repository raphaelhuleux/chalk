import { describe, it, expect } from 'vitest';
import { scanMathRegions } from '../../src/webview/editor/tex-math';

describe('scanMathRegions', () => {
  it('finds no regions in plain text', () => {
    expect(scanMathRegions('Hello, world.')).toEqual([]);
  });

  it('finds a single inline $...$ region', () => {
    const regions = scanMathRegions('Let $x = 1$ be a number.');
    expect(regions).toHaveLength(1);
    expect(regions[0]).toMatchObject({
      from: 4,
      to: 11,
      display: false,
      content: 'x = 1',
    });
  });

  it('finds a display $$...$$ region', () => {
    const regions = scanMathRegions('Before.\n$$a+b$$\nAfter.');
    expect(regions).toHaveLength(1);
    expect(regions[0]).toMatchObject({
      display: true,
      content: 'a+b',
    });
  });

  it('finds $$...$$ spanning multiple lines', () => {
    const src = 'x\n$$\n\\int_0^1 f\n$$\ny';
    const regions = scanMathRegions(src);
    expect(regions).toHaveLength(1);
    expect(regions[0].display).toBe(true);
    expect(regions[0].content).toBe('\n\\int_0^1 f\n');
  });

  it('finds \\(...\\) inline and \\[...\\] display', () => {
    const src = 'A \\(x\\) and B \\[y\\].';
    const regions = scanMathRegions(src);
    expect(regions).toHaveLength(2);
    expect(regions[0]).toMatchObject({ display: false, content: 'x' });
    expect(regions[1]).toMatchObject({ display: true, content: 'y' });
  });

  it('finds a \\begin{equation}...\\end{equation} block', () => {
    const src = 'Before\n\\begin{equation}\na = b\n\\end{equation}\nAfter';
    const regions = scanMathRegions(src);
    expect(regions).toHaveLength(1);
    expect(regions[0].display).toBe(true);
    // content includes \begin/\end so KaTeX parses the environment
    expect(regions[0].content).toContain('\\begin{equation}');
    expect(regions[0].content).toContain('\\end{equation}');
    expect(regions[0].content).toContain('a = b');
  });

  it('handles align* and other starred variants', () => {
    const src = '\\begin{align*}x &= 1 \\\\ y &= 2\\end{align*}';
    const regions = scanMathRegions(src);
    expect(regions).toHaveLength(1);
    expect(regions[0].content).toContain('\\begin{align*}');
  });

  it('ignores \\begin{unknown}...\\end{unknown} for non-math environments', () => {
    const src = '\\begin{itemize}\n\\item foo\n\\end{itemize}';
    expect(scanMathRegions(src)).toEqual([]);
  });

  it('treats \\$ as a literal dollar, not a delimiter', () => {
    const src = 'Cost is \\$5 per item, and $x$ is math.';
    const regions = scanMathRegions(src);
    expect(regions).toHaveLength(1);
    expect(regions[0].content).toBe('x');
  });

  it('skips %-comments entirely', () => {
    const src = '% a comment with $fake$\nReal: $x$';
    const regions = scanMathRegions(src);
    expect(regions).toHaveLength(1);
    expect(regions[0].content).toBe('x');
  });

  it('applies offset to every returned position', () => {
    const regions = scanMathRegions('$x$', 100);
    expect(regions[0]).toMatchObject({ from: 100, to: 103 });
  });

  it('skips an unmatched $ without crashing', () => {
    const regions = scanMathRegions('This $is unclosed.');
    expect(regions).toEqual([]);
  });

  it('picks multiple regions in one string in document order', () => {
    const regions = scanMathRegions('$a$ then $$b$$ and \\(c\\).');
    expect(regions.map((r) => r.content)).toEqual(['a', 'b', 'c']);
    expect(regions.map((r) => r.display)).toEqual([false, true, false]);
    // Ordered by position.
    expect(regions[0].from).toBeLessThan(regions[1].from);
    expect(regions[1].from).toBeLessThan(regions[2].from);
  });

  it('does not consume text between regions', () => {
    const regions = scanMathRegions('$a$ X $b$');
    expect(regions).toHaveLength(2);
    expect(regions[0].to).toBe(3); // "$a$"
    expect(regions[1].from).toBe(6); // " X " is 3 chars, so next $ at 6
  });
});
