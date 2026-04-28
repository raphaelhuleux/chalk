import { describe, it, expect, beforeAll } from 'vitest';
import { EditorView } from '@codemirror/view';
import { EditorState, EditorSelection } from '@codemirror/state';
import { scanForExit, taboutCommand } from '../../src/webview/editor/tabout';

beforeAll(() => {
  if (typeof Range.prototype.getClientRects !== 'function') {
    Range.prototype.getClientRects = () => [] as unknown as DOMRectList;
  }
  if (typeof Range.prototype.getBoundingClientRect !== 'function') {
    Range.prototype.getBoundingClientRect = () =>
      ({ x: 0, y: 0, width: 0, height: 0, top: 0, right: 0, bottom: 0, left: 0, toJSON: () => ({}) }) as DOMRect;
  }
});

function makeView(doc: string, cursor: number): EditorView {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  const state = EditorState.create({
    doc,
    selection: EditorSelection.cursor(cursor),
  });
  return new EditorView({ state, parent });
}

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

describe('taboutCommand', () => {
  it('inside math: Tab past `}` jumps the cursor', () => {
    // 'a{b}c' — `}` is at index 3
    const view = makeView('a{b}c', 2);
    const cmd = taboutCommand(() => true, 'tex');
    expect(cmd(view)).toBe(true);
    expect(view.state.selection.main.head).toBe(4);
    view.destroy();
  });

  it('outside math: Tab is a no-op (returns false)', () => {
    const view = makeView('a{b}c', 2);
    const cmd = taboutCommand(() => false, 'tex');
    expect(cmd(view)).toBe(false);
    expect(view.state.selection.main.head).toBe(2);
    view.destroy();
  });

  it('inside math, no closing delim: Tab returns false', () => {
    const view = makeView('abc', 0);
    const cmd = taboutCommand(() => true, 'tex');
    expect(cmd(view)).toBe(false);
    view.destroy();
  });

  it('non-empty selection: Tab returns false (lets indent handle it)', () => {
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const state = EditorState.create({
      doc: 'a{b}c',
      selection: EditorSelection.range(0, 4),
    });
    const view = new EditorView({ state, parent });
    const cmd = taboutCommand(() => true, 'tex');
    expect(cmd(view)).toBe(false);
    view.destroy();
  });
});

describe('taboutCommand — spec worked examples', () => {
  // Doc strings use JS escapes — `\\` is one `\` in the actual document.
  const cases: [string, string, number, number][] = [
    // $\frac{a|}{b}$   →  $\frac{a}|{b}$  (cursor 7 → past first } at 9)
    // chars: $ \ f r a c { a } { b } $
    // index: 0 1 2 3 4 5 6 7 8 9 10 11 12
    ['frac inside first arg', '$\\frac{a}{b}$', 7, 9],
    // $\frac{a}|{b}$   →  $\frac{a}{b}|$  (cursor 9 → past second } at 12)
    ['frac between args', '$\\frac{a}{b}$', 9, 12],
    // $\frac{a}{b}|$   →  $\frac{a}{b}$|  (cursor 12 → past closing $ at 13)
    ['frac after second }', '$\\frac{a}{b}$', 12, 13],
    // $\sin(x|)$       →  $\sin(x)|$
    // chars: $ \ s i n ( x ) $
    // index: 0 1 2 3 4 5 6 7 8
    ['inside parens', '$\\sin(x)$', 7, 8],
    // $\left(a|\right) + b$  →  $\left(a\right)| + b$
    // chars: $ \ l e f t ( a \ r  i  g  h  t  )  ' '  +  ' '  b  $
    // index: 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19
    // Cursor at 8 = at `\` of \right. Scanner returns past `\right)` → 15.
    ['left-right group', '$\\left(a\\right) + b$', 8, 15],
  ];

  for (const [name, doc, cur, expected] of cases) {
    it(name, () => {
      const view = makeView(doc, cur);
      const cmd = taboutCommand(() => true, 'tex');
      cmd(view);
      expect(view.state.selection.main.head).toBe(expected);
      view.destroy();
    });
  }
});
