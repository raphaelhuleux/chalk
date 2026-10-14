import { describe, it, expect, afterEach, beforeEach, vi } from 'vitest';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { markdown } from '@codemirror/lang-markdown';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { mathSyntax, isInMathContextMd } from '../src/editor/md-math-plugin';
import { destroyViews, mdView } from './helpers/views';

/**
 * Pandoc's rule: `$$…$$` anywhere in a paragraph is display math. Lecture-note
 * prose routinely reads "this becomes $$ c_0 = … $$ so consumption is …", and
 * the equation used to stay raw source: the block parser only fires at a line
 * start and the inline parser refused `$$` outright.
 *
 * The paragraph-interior form is its own node, `InlineDisplayMath`, so the
 * block form's whole-line assumptions (line-based reveal, `blockReplaceFrom`,
 * the Up/Down "enter the block" keymap) never apply to it. It renders as an
 * INLINE replace whose widget forces its own row — never a `block: true`
 * replace mid-line, which splits the document line into two `.cm-line`s.
 */

const PARAGRAPH =
  'Assuming $\\beta R =1$, this becomes $$ c_{0} = \\frac{r}{1+r}(s_{0}+h_{0}) $$ ' +
  '$\\Rightarrow$ Consumption is the annuity value of total wealth';

function makeState(doc: string): EditorState {
  const state = EditorState.create({
    doc,
    extensions: [markdown({ extensions: [mathSyntax] })],
  });
  ensureSyntaxTree(state, state.doc.length, 5000);
  return state;
}

function nodesOf(state: EditorState, name: string): Array<{ from: number; to: number }> {
  const out: Array<{ from: number; to: number }> = [];
  syntaxTree(state).iterate({
    enter(n) {
      if (n.name === name) out.push({ from: n.from, to: n.to });
    },
  });
  return out;
}

describe('paragraph-interior $$…$$ parsing', () => {
  it('parses as InlineDisplayMath with two marks, leaving the $…$ spans inline', () => {
    const state = makeState(PARAGRAPH);
    const from = PARAGRAPH.indexOf('$$');
    const to = PARAGRAPH.lastIndexOf('$$') + 2;
    expect(nodesOf(state, 'InlineDisplayMath')).toEqual([{ from, to }]);
    expect(nodesOf(state, 'InlineDisplayMathMark')).toEqual([
      { from, to: from + 2 },
      { from: to - 2, to },
    ]);
    expect(nodesOf(state, 'InlineMath')).toHaveLength(2);
    expect(nodesOf(state, 'DisplayMath')).toHaveLength(0);
  });

  it('keeps a line-start $$ as the block form', () => {
    const state = makeState('$$ x = y $$\n');
    expect(nodesOf(state, 'DisplayMath')).toHaveLength(1);
    expect(nodesOf(state, 'InlineDisplayMath')).toHaveLength(0);
  });

  it('spans a hard-wrapped source line', () => {
    const doc = 'this becomes $$ c_0 =\n\\frac{r}{1+r} w $$ and so on';
    const state = makeState(doc);
    expect(nodesOf(state, 'InlineDisplayMath')).toEqual([
      { from: doc.indexOf('$$'), to: doc.lastIndexOf('$$') + 2 },
    ]);
  });

  it('does not reach across a paragraph break', () => {
    const state = makeState('cost is $$ 5\n\nand $$ 7');
    expect(nodesOf(state, 'InlineDisplayMath')).toHaveLength(0);
    expect(nodesOf(state, 'InlineMath')).toHaveLength(0);
  });

  it('leaves an unclosed or empty $$ as prose', () => {
    expect(nodesOf(makeState('cost $$ 5'), 'InlineDisplayMath')).toHaveLength(0);
    expect(nodesOf(makeState('a $$$$ b'), 'InlineDisplayMath')).toHaveLength(0);
  });

  it('is a math context for snippets', () => {
    const state = makeState(PARAGRAPH);
    expect(isInMathContextMd(state, PARAGRAPH.indexOf('c_{0}') + 1)).toBe(true);
    expect(isInMathContextMd(state, PARAGRAPH.indexOf('this') + 1)).toBe(false);
  });
});

// ---------------------------------------------------------------------------

const mount = (content: string): EditorView => mdView(content);

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
  destroyViews();
});

const displays = (v: EditorView) => [...v.dom.querySelectorAll<HTMLElement>('.cm-math-display')];

describe('paragraph-interior $$…$$ rendering', () => {
  it('renders a display widget with the source concealed, inside the line', () => {
    const v = mount(PARAGRAPH);
    const ds = displays(v);
    expect(ds).toHaveLength(1);
    expect(ds[0].innerHTML).toContain('katex');
    const text = v.contentDOM.textContent ?? '';
    expect(text).not.toContain('$$');
    expect(text).toContain('this becomes');
    expect(text).toContain('Consumption');
    // Inline replace: the widget lives INSIDE the one `.cm-line`, which is
    // not split around it.
    expect(ds[0].closest('.cm-line')).not.toBeNull();
    expect(v.contentDOM.querySelectorAll('.cm-line')).toHaveLength(1);
  });

  it('breaks the row before the equation with a forced line break', () => {
    // A forced break (not a wrapped one) is what keeps the prose row before
    // the equation aligned to the start under `text-align: justify`; the
    // equation row itself is a full-width inline-block so no anonymous block
    // boxes appear (they would inherit the hanging-indent `text-indent`).
    const v = mount(PARAGRAPH);
    const row = displays(v)[0];
    expect(row.previousSibling?.nodeName).toBe('BR');
  });

  it('reveals the source with a preview under the paragraph while the caret is inside', () => {
    const v = mount(PARAGRAPH);
    v.dispatch({ selection: { anchor: PARAGRAPH.indexOf('c_{0}') + 1 } });
    expect(displays(v)).toHaveLength(0);
    expect(v.dom.querySelectorAll('.cm-math-editing')).toHaveLength(1);
    expect(v.contentDOM.textContent).toContain('$$ c_{0}');
    const preview = v.dom.querySelector<HTMLElement>('.cm-math-preview');
    expect(preview).not.toBeNull();
    expect(preview!.innerHTML).toContain('katex');
    // Under the whole paragraph line, not mid-row.
    const line = preview!.previousElementSibling;
    expect(line?.classList.contains('cm-line')).toBe(true);
    expect(line?.textContent).toContain('Consumption');
  });

  it('keeps the source revealed for a selection inside the equation', () => {
    const v = mount(PARAGRAPH);
    const a = PARAGRAPH.indexOf('c_{0}');
    v.dispatch({ selection: { anchor: a, head: a + 5 } });
    expect(displays(v)).toHaveLength(0);
    expect(v.dom.querySelectorAll('.cm-math-editing')).toHaveLength(1);
  });

  it('renders again once the caret leaves', () => {
    const v = mount(PARAGRAPH);
    v.dispatch({ selection: { anchor: PARAGRAPH.indexOf('c_{0}') + 1 } });
    v.dispatch({ selection: { anchor: 2 } });
    expect(displays(v)).toHaveLength(1);
    expect(v.dom.querySelector('.cm-math-preview')).toBeNull();
  });

  it('refreshes the preview on the keystroke while rendering is cheap', () => {
    const v = mount(PARAGRAPH);
    const at = PARAGRAPH.indexOf('c_{0}') + 1;
    v.dispatch({ selection: { anchor: at } });
    const before = v.dom.querySelector<HTMLElement>('.cm-math-preview')!.innerHTML;
    v.dispatch({
      changes: { from: at, insert: 'z' },
      selection: { anchor: at + 1 },
    });
    const after = v.dom.querySelector<HTMLElement>('.cm-math-preview')!;
    expect(after.innerHTML).not.toBe(before);
    expect(after.textContent).toContain('z');
  });

  it('leaves a slow render to the debouncer', () => {
    const v = mount(PARAGRAPH);
    const at = PARAGRAPH.indexOf('c_{0}') + 1;
    // Every clock read is 50ms after the last: each render measures over budget.
    let clock = 0;
    const now = vi.spyOn(performance, 'now').mockImplementation(() => (clock += 50));
    try {
      v.dispatch({ selection: { anchor: at } });
      const before = v.dom.querySelector<HTMLElement>('.cm-math-preview')!.innerHTML;
      v.dispatch({
        changes: { from: at, insert: 'z' },
        selection: { anchor: at + 1 },
      });
      expect(v.dom.querySelector<HTMLElement>('.cm-math-preview')!.innerHTML).toBe(before);
      vi.advanceTimersByTime(200);
      const after = v.dom.querySelector<HTMLElement>('.cm-math-preview')!;
      expect(after.innerHTML).not.toBe(before);
      expect(after.textContent).toContain('z');
    } finally {
      now.mockRestore();
    }
  });

  it('counts toward automatic equation numbering', () => {
    const v = mount(
      'intro $$\\begin{equation} a = b \\end{equation}$$ tail\n\n$$\n\\begin{equation} c = d \\end{equation}\n$$\n',
    );
    const ds = displays(v);
    expect(ds).toHaveLength(2);
    expect(ds[0].style.getPropertyValue('--chalk-eq-offset')).toBe('0');
    expect(ds[1].style.getPropertyValue('--chalk-eq-offset')).toBe('1');
  });

  it('renders a hard-wrapped equation as one widget', () => {
    const v = mount('this becomes $$ c_0 =\n\\frac{r}{1+r} w $$ and so on');
    expect(displays(v)).toHaveLength(1);
    expect(v.contentDOM.textContent).not.toContain('$$');
  });
});
