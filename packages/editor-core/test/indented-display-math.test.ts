import { describe, it, expect, afterEach } from 'vitest';
import { EditorView } from '@codemirror/view';
import { destroyViews, langView } from './helpers/views';

/**
 * Display math indented inside a list item — the house shape for reading notes,
 * where the equation is a continuation line of its bullet:
 *
 *     - **Households**: the budget constraint is
 *       $$c_t + M_t/p_t = y$$
 *
 * CM6's contract is that a `block: true` decoration covers WHOLE lines. Both
 * math builders used to replace from the construct's own offset, which inside a
 * list item is the content indent, not the line start. Given a mid-line `from`,
 * the leading whitespace opens a real `.cm-line` of its own and the widget is
 * appended as a sibling: one document line becomes two DOM blocks and two
 * height-map nodes.
 *
 * Visible symptom: a stray blank row above every indented equation, and a
 * height map that no longer pairs one line to one node — the precondition for
 * the widget-overlaps-text class fixed twice before (`bd4811d`, `87a3e0b`).
 *
 * Owner-reported 2026-08-17 on a markdown file whose three equations are all
 * indented two spaces inside bullets. No repo fixture indented display math,
 * which is why nothing caught it.
 */

const mount = (content: string, language: 'md' | 'tex'): EditorView =>
  langView(content, language);

afterEach(destroyViews);

/** `.cm-line` elements holding nothing but whitespace — the stray rows. */
function blankRows(v: EditorView): string[] {
  return [...v.contentDOM.children]
    .filter((e) => e.classList.contains('cm-line'))
    .map((e) => e.textContent ?? '')
    .filter((t) => t.length > 0 && t.trim().length === 0);
}

function widgetCount(v: EditorView, selector: string): number {
  return v.dom.querySelectorAll(selector).length;
}

describe('indented display math (md)', () => {
  it('renders the widget without leaving the indent as a stray row', () => {
    const v = mount('- item text here\n  $$a+b=c$$\n- next item\n', 'md');
    expect(widgetCount(v, '.cm-math-display')).toBe(1);
    expect(blankRows(v)).toEqual([]);
  });

  it('is indifferent to whether the indent sits in a list', () => {
    const v = mount('para text here\n\n  $$a+b=c$$\n\nmore text\n', 'md');
    expect(widgetCount(v, '.cm-math-display')).toBe(1);
    expect(blankRows(v)).toEqual([]);
  });

  it('still has no stray row at column 0 (the case that always worked)', () => {
    const v = mount('para text here\n\n$$a+b=c$$\n\nmore text\n', 'md');
    expect(widgetCount(v, '.cm-math-display')).toBe(1);
    expect(blankRows(v)).toEqual([]);
  });

  it('replaces from the line start, so one document line is one block', () => {
    const v = mount('- item text here\n  $$a+b=c$$\n- next item\n', 'md');
    const lineStart = v.state.doc.line(2).from;
    let from = -1;
    v.state
      .facet(EditorView.decorations)
      .flatMap((d) => (typeof d === 'function' ? [d(v)] : [d]))
      .forEach((set) => {
        set.between(lineStart, v.state.doc.line(2).to, (f, _t, deco) => {
          if (deco.spec.block && deco.spec.widget) from = f;
        });
      });
    expect(from).toBe(lineStart);
  });

  it('keeps the caret reachable on the equation line', () => {
    const v = mount('- item text here\n  $$a+b=c$$\n- next item\n', 'md');
    const line = v.state.doc.line(2);
    v.dispatch({ selection: { anchor: line.from + 2 } });
    // Caret inside the block reveals the source; the widget un-renders.
    expect(widgetCount(v, '.cm-math-display')).toBe(0);
    expect(v.state.doc.toString()).toContain('  $$a+b=c$$');
  });
});

describe('indented display math (tex)', () => {
  it('renders \\[ … \\] indented without a stray row', () => {
    const v = mount('Some prose here.\n  \\[ a+b=c \\]\nMore prose.\n', 'tex');
    expect(widgetCount(v, '.cm-tex-math-display')).toBe(1);
    expect(blankRows(v)).toEqual([]);
  });

  it('still has no stray row at column 0', () => {
    const v = mount('Some prose here.\n\\[ a+b=c \\]\nMore prose.\n', 'tex');
    expect(widgetCount(v, '.cm-tex-math-display')).toBe(1);
    expect(blankRows(v)).toEqual([]);
  });

  it('a click on the indented widget lands the caret at the region start', () => {
    // posAtDOM returns the block replace's start (the line start), which sits
    // before the region's own `from`; the snap must still find the region.
    const doc = 'Some prose here.\n  \\[ a+b=c \\]\nMore prose.\n';
    const v = mount(doc, 'tex');
    v.dispatch({ selection: { anchor: doc.indexOf('More') } });
    const widget = v.dom.querySelector('.cm-tex-math-display')!;
    widget.dispatchEvent(new MouseEvent('mousedown', { button: 0, bubbles: true, cancelable: true }));
    expect(v.state.selection.main.head).toBe(doc.indexOf('\\['));
  });

  it('handles an indented equation environment', () => {
    const v = mount(
      'Prose above.\n  \\begin{equation}\n  a+b=c\n  \\end{equation}\nProse below.\n',
      'tex',
    );
    expect(widgetCount(v, '.cm-tex-math-display')).toBe(1);
    expect(blankRows(v)).toEqual([]);
  });
});
