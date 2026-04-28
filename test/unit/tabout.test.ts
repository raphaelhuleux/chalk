import { describe, it, expect } from 'vitest';
import { scanForExit } from '../../src/webview/editor/tabout';

describe('scanForExit', () => {
  it('returns position just past the next closing }', () => {
    expect(scanForExit('a}b', 0, 'tex')).toBe(2);
  });

  it('returns position just past the next closing ]', () => {
    expect(scanForExit('a]b', 0, 'tex')).toBe(2);
  });

  it('returns position just past the next closing )', () => {
    expect(scanForExit('a)b', 0, 'tex')).toBe(2);
  });

  it('returns null when no closing delim found', () => {
    expect(scanForExit('abc', 0, 'tex')).toBe(null);
  });
});

describe('scanForExit — math-close delimiters', () => {
  it('returns past a single $ (inline math close)', () => {
    expect(scanForExit('a$b', 0, 'tex')).toBe(2);
  });

  it('returns past $$ (display math close) as a unit', () => {
    expect(scanForExit('a$$b', 0, 'tex')).toBe(3);
  });

  it('returns past \\) (inline math close)', () => {
    expect(scanForExit('a\\)b', 0, 'tex')).toBe(3);
  });

  it('returns past \\] (display math close)', () => {
    expect(scanForExit('a\\]b', 0, 'tex')).toBe(3);
  });

  it('returns past \\end{align}', () => {
    expect(scanForExit('a\\end{align}b', 0, 'tex')).toBe(12);
  });
});

describe('scanForExit — escape handling', () => {
  it('skips \\} so the literal close brace is not an exit', () => {
    // text "a\}b}c" → indices a=0 \=1 }=2 b=3 }=4 c=5
    // scanner from 0: a (advance), \} skip 2 → i=3, b (advance) → i=4, } → return 5
    expect(scanForExit('a\\}b}c', 0, 'tex')).toBe(5);
  });

  it('skips \\$ so the literal dollar is not a math close', () => {
    // text "a\$b$c" → indices a=0 \=1 $=2 b=3 $=4 c=5
    // scanner: a, \$ skip → i=3, b, $ → return 5
    expect(scanForExit('a\\$b$c', 0, 'tex')).toBe(5);
  });

  it('skips \\\\ (literal backslash)', () => {
    // text "a\\}b" → indices a=0 \=1 \=2 }=3 b=4
    // scanner: a, \\ skip → i=3, } → return 4
    expect(scanForExit('a\\\\}b', 0, 'tex')).toBe(4);
  });
});

describe('scanForExit — tex line comments', () => {
  it('skips a }} hidden inside a % comment to find a later real }', () => {
    // text "a%}}\n}b" → indices a=0 %=1 }=2 }=3 \n=4 }=5 b=6
    // scanner: a, % → skip to 5 (after \n), } → return 6
    expect(scanForExit('a%}}\n}b', 0, 'tex')).toBe(6);
  });

  it('does NOT skip % in markdown', () => {
    // text "a%}b" → first } at index 2, return 3
    expect(scanForExit('a%}b', 0, 'md')).toBe(3);
  });
});

describe('scanForExit — \\left … \\right pairing', () => {
  it('jumps past \\right) when no \\left was opened in the scan', () => {
    // text "a\right) b" → indices a=0 \=1 r=2 i=3 g=4 h=5 t=6 )=7 ' '=8 b=9
    // scanner: a, then at i=1 `\right` matched, readDelim at 7 → ) → return 8
    expect(scanForExit('a\\right) b', 0, 'tex')).toBe(8);
  });

  it('balances an inner \\left … \\right and exits at outer \\right', () => {
    // text "\left( x \right) \right] more"
    //  indices 0..5  6 7 8 9..14 15 16 17..22 23 24..27
    // \left( pushes; \right) pops; \right] is the exit; return after ]
    const src = '\\left( x \\right) \\right] more';
    expect(scanForExit(src, 0, 'tex')).toBe(24);
  });

  it('does not match \\leftarrow as \\left', () => {
    // text "\leftarrow}b" → \leftarrow is NOT \left (next char is letter)
    // scanner: \ at 0, startsWith('\\left',0) but text[5]='a' is letter → not \left
    //  fall to escape skip: i += 2 → i=2 (e), advance e..w → at } → return
    // text indices: \=0 l=1 e=2 f=3 t=4 a=5 r=6 r=7 o=8 w=9 }=10 b=11
    expect(scanForExit('\\leftarrow}b', 0, 'tex')).toBe(11);
  });

  it('handles \\right with multi-char letter delim like \\rangle', () => {
    // text "\right\rangle x" — indices \=0 r=1..t=5 \=6 r=7..e=12 ' '=13 x=14
    // \right (0..5), readDelim at 6: \ then letters r,a,n,g,l,e → return 13
    expect(scanForExit('\\right\\rangle x', 0, 'tex')).toBe(13);
  });
});
