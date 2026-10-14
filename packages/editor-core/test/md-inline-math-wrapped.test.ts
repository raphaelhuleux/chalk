import { describe, it, expect, afterEach } from 'vitest';
import { EditorView } from '@codemirror/view';
import { destroyViews, mdView } from './helpers/views';

/**
 * Hard-wrapped prose is the house style for this editor's users, so an inline
 * `$…$` routinely straddles a source line break. LaTeX documents already render
 * those (tex-math's scanner stops only at a paragraph break); markdown used to
 * bail on the first newline, leaving the raw `$\hat\beta = (X^\top` … `y$`
 * visible mid-paragraph.
 *
 * Rendering one needs a replace decoration that covers a line break, which CM6
 * forbids from a ViewPlugin — so the wrapped case is served by
 * `displayMathField` while single-line spans stay on the (viewport-limited)
 * view plugin.
 */
const mount = (content: string): EditorView => mdView(content);

afterEach(destroyViews);

function rendered(v: EditorView): string[] {
  return [...v.dom.querySelectorAll('.cm-math-inline')].map((e) => e.textContent ?? '');
}

describe('inline math wrapped across a source line', () => {
  it('renders a span that starts on one line and closes on the next', () => {
    const v = mount(
      'estimator is generalised least squares, $\\hat\\beta = (X^\\top\n\\Omega^{-1} X)^{-1} y$ and so on.\n',
    );
    expect(rendered(v).length).toBe(1);
  });

  it('leaves the raw source visible while the caret is inside it', () => {
    const v = mount('a $x +\ny$ b\n');
    expect(rendered(v).length).toBe(1);
    v.dispatch({ selection: { anchor: v.state.doc.line(1).from + 4 } });
    expect(rendered(v).length).toBe(0);
    expect(v.state.doc.toString()).toContain('$x +\ny$');
  });

  it('does not reach across a paragraph break', () => {
    const v = mount('cost is $5 today\n\nand $7 tomorrow\n');
    expect(rendered(v).length).toBe(0);
  });

  it('strips the `>` continuation markers inside a blockquote', () => {
    const v = mount('> a $x +\n> y$ b\n');
    const spans = rendered(v);
    expect(spans.length).toBe(1);
    expect(spans[0]).not.toContain('>');
  });

  it('keeps single-line spans rendering as before', () => {
    const v = mount('one $a$ and two $b$ on a line\n');
    expect(rendered(v).length).toBe(2);
  });

  it('survives without CM6 throwing on a line-break-spanning replacement', () => {
    const errors: unknown[] = [];
    const orig = console.error;
    console.error = (...a: unknown[]) => errors.push(a);
    try {
      mount('intro\n\ntext $\\alpha +\n\\beta$ tail\n\nmore\n');
    } finally {
      console.error = orig;
    }
    expect(errors).toEqual([]);
  });
});
