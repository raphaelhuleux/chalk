import { describe, it, expect, afterEach } from 'vitest';
import { EditorState } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { markdown } from '@codemirror/lang-markdown';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { highlightTree, tags as t } from '@lezer/highlight';

type Tree = NonNullable<ReturnType<typeof ensureSyntaxTree>>;
import {
  normalizeFenceInfo,
  mdCodeLanguages,
} from '../src/editor/code-languages';
import { codeHighlightStyle } from '../src/editor/code-syntax-highlight';
import { destroyViews, mdView } from './helpers/views';

// ---------------------------------------------------------------------------
//  Fence info normalization (pure)
// ---------------------------------------------------------------------------

describe('normalizeFenceInfo', () => {
  it.each([
    ['python', 'python'],
    ['{python}', 'python'],
    ['{python, echo=false}', 'python'],
    ['{.python}', 'python'],
    ['{r}', 'r'],
    ['R', 'r'],
    ['jl', 'jl'],
    ['py', 'py'],
    ['', ''],
    ['   ', ''],
    ['{}', ''],
  ])('%j → %j', (info, expected) => {
    expect(normalizeFenceInfo(info)).toBe(expected);
  });
});

describe('mdCodeLanguages', () => {
  it('resolves plain and Quarto info strings to the same language', () => {
    const plain = mdCodeLanguages('python');
    expect(plain?.name).toBe('python');
    expect(mdCodeLanguages('{python}')).toBe(plain);
    expect(mdCodeLanguages('{python, echo=false}')).toBe(plain);
    expect(mdCodeLanguages('py')).toBe(plain);
    expect(mdCodeLanguages('{r}')?.name).toBe('r');
    expect(mdCodeLanguages('{julia}')?.name).toBe('julia');
    expect(mdCodeLanguages('jl')?.name).toBe('julia');
  });

  it('returns null for languages we do not ship', () => {
    expect(mdCodeLanguages('bash')).toBeNull();
    expect(mdCodeLanguages('')).toBeNull();
  });

  it('labels unshipped languages anyway', () => {
    expect(normalizeFenceInfo('{bash}')).toBe('bash');
  });
});

// ---------------------------------------------------------------------------
//  Nested parsing + token highlighting (tree-only)
// ---------------------------------------------------------------------------

/**
 * Returns the state together with the tree `ensureSyntaxTree` produced.
 *
 * Both are needed: `ensureSyntaxTree` advances the parse context and hands
 * back the completed tree, but it does NOT refresh the language field, so
 * `syntaxTree(state)` keeps returning whatever the initial time-budgeted
 * parse managed to finish. On an idle machine that is the whole document and
 * the difference is invisible; under load the fence's nested language is
 * missing from the field's tree and the highlighting assertions fail.
 */
async function makeState(doc: string): Promise<{ state: EditorState; tree: Tree }> {
  // Pre-load the nested languages so the mixed parser can mount them
  // synchronously inside ensureSyntaxTree (load() resolves eagerly).
  for (const info of ['python', 'r', 'julia']) await mdCodeLanguages(info)!.load();
  const state = EditorState.create({
    doc,
    extensions: [markdown({ codeLanguages: mdCodeLanguages })],
  });
  const tree = ensureSyntaxTree(state, state.doc.length, 5000);
  if (!tree) throw new Error('parse did not finish within the budget');
  return { state, tree };
}

function styledRanges({ state, tree }: { state: EditorState; tree: Tree }): { text: string; cls: string }[] {
  const out: { text: string; cls: string }[] = [];
  highlightTree(tree, codeHighlightStyle, (from, to, cls) => {
    out.push({ text: state.sliceDoc(from, to), cls });
  });
  return out;
}

const kwClass = codeHighlightStyle.style([t.keyword])!;
const commentClass = codeHighlightStyle.style([t.comment])!;

describe('nested fence highlighting', () => {
  it('highlights python inside a Quarto fence', async () => {
    const state = await makeState('```{python}\ndef f(x):\n    return x  # doubles\n```\n');
    const ranges = styledRanges(state);
    expect(ranges.some((r) => r.text === 'def' && r.cls.includes(kwClass))).toBe(true);
    expect(ranges.some((r) => r.text.includes('# doubles') && r.cls.includes(commentClass))).toBe(true);
  });

  it('highlights python inside a plain fence', async () => {
    const state = await makeState('```python\nreturn 1\n```\n');
    expect(styledRanges(state).some((r) => r.text === 'return' && r.cls.includes(kwClass))).toBe(true);
  });

  it('highlights R inside a Quarto fence', async () => {
    const state = await makeState('```{r, echo=false}\nif (x) y <- 1  # note\n```\n');
    const ranges = styledRanges(state);
    expect(ranges.some((r) => r.text === 'if' && r.cls.includes(kwClass))).toBe(true);
    expect(ranges.some((r) => r.text.includes('# note') && r.cls.includes(commentClass))).toBe(true);
  });

  it('leaves an unshipped language unstyled', async () => {
    const state = await makeState('```bash\nif true; then echo hi; fi\n```\n');
    expect(styledRanges(state)).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
//  Block decorations (jsdom view)
// ---------------------------------------------------------------------------

// Finish the parse, then nudge a transaction so the code-block field's
// tree-identity check rebuilds against the completed tree (same recipe as
// the frontmatter dim test).
const mount = (doc: string): EditorView => mdView(doc, { ensureTree: true, cursor: 0 });

afterEach(destroyViews);

const PY_BLOCK = 'before\n\n```{python}\nx = 1\ny = 2\n```\n\nafter';

describe('code block decorations', () => {
  it('paints the band with top/bottom lines and a language label', () => {
    const view = mount(PY_BLOCK);
    const lines = view.dom.querySelectorAll('.cm-line.cm-codeblock');
    expect(lines.length).toBe(4); // open fence, x, y, close fence
    expect(view.dom.querySelector('.cm-codeblock-top')?.getAttribute('data-lang')).toBe('python');
    expect(view.dom.querySelector('.cm-codeblock-bottom')).not.toBeNull();
  });

  it('dims the fences but keeps them in the DOM', () => {
    const view = mount(PY_BLOCK);
    const fences = view.dom.querySelectorAll('.cm-codeblock-fence');
    expect(fences.length).toBeGreaterThanOrEqual(2); // ``` marks (+ info string)
    const text = view.dom.querySelector('.cm-content')!.textContent ?? '';
    expect(text).toContain('```');
    expect(text).toContain('{python}');
  });

  it('omits data-lang on a bare fence', () => {
    const view = mount('```\nplain text\n```\n');
    const top = view.dom.querySelector('.cm-codeblock-top');
    expect(top).not.toBeNull();
    expect(top!.hasAttribute('data-lang')).toBe(false);
  });

  it('Cmd+: source mode drops the band', () => {
    const view = mount(PY_BLOCK);
    expect(view.dom.querySelector('.cm-codeblock')).not.toBeNull();
    // Cmd+: cycles preview → mixed → source; two presses reach source.
    const press = () =>
      view.contentDOM.dispatchEvent(
        new KeyboardEvent('keydown', { key: ':', ctrlKey: true, bubbles: true, cancelable: true }),
      );
    press();
    press();
    expect(view.dom.querySelector('.cm-codeblock')).toBeNull();
  });
});

describe('coexistence', () => {
  it('renders a fence inside a callout with both bands', () => {
    const view = mount('::: {.remark}\n```{python}\nx = 1\n```\n:::\n');
    expect(view.dom.querySelector('.cm-codeblock')).not.toBeNull();
    expect(view.dom.querySelector('.cm-callout')).not.toBeNull();
  });

  it('does not treat $$ inside a fence as display math', () => {
    const view = mount('```python\n$$\nx = 1\n$$\n```\n');
    let sawMath = false;
    syntaxTree(view.state).iterate({
      enter: (n) => {
        if (n.name === 'DisplayMath') sawMath = true;
      },
    });
    expect(sawMath).toBe(false);
    expect(view.dom.querySelector('.cm-math-display')).toBeNull();
  });
});
