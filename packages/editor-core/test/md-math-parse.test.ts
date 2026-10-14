import { describe, it, expect, beforeEach } from 'vitest';
import { EditorState } from '@codemirror/state';
import { markdown } from '@codemirror/lang-markdown';
import { ensureSyntaxTree, syntaxTree, syntaxTreeAvailable } from '@codemirror/language';
import { mathSyntax } from '../src/editor/md-math-plugin';
import { createEditor } from '../src/editor/setup';
import { parsed } from './helpers/force-parse';
import { mdView } from './helpers/views';

/** Full-parse markdown state (see md-math-context.test.ts for why). */
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

// ---------------------------------------------------------------------------
// Unclosed $$ — the block parser must CLAIM consumed lines (Lezer contract).
// Before the fix, `$$` with no closer consumed to EOF then returned false,
// which collapsed the parse tree to a childless Document: every heading /
// bold / block below an in-progress `$$` lost its structure while typing.
// ---------------------------------------------------------------------------

describe('unclosed $$ block', () => {
  it('claims to EOF with a single open mark instead of wrecking the tree', () => {
    const state = makeState('$$\nx+1\n\n# heading\n\n**bold**');
    const blocks = nodesOf(state, 'DisplayMath');
    expect(blocks).toHaveLength(1);
    expect(blocks[0]).toEqual({ from: 0, to: state.doc.length });
    expect(nodesOf(state, 'DisplayMathMark')).toHaveLength(1);
  });

  it('closed variant keeps two marks and the heading below', () => {
    const state = makeState('$$\nx+1\n$$\n\n# heading\n\n**bold**');
    expect(nodesOf(state, 'DisplayMath')).toHaveLength(1);
    expect(nodesOf(state, 'DisplayMathMark')).toHaveLength(2);
    expect(nodesOf(state, 'ATXHeading1')).toHaveLength(1);
    expect(nodesOf(state, 'StrongEmphasis')).toHaveLength(1);
  });

  it('typing the closing $$ later restores the blocks below (incremental)', () => {
    const s1 = makeState('$$\nx+1\n\n# heading');
    expect(nodesOf(s1, 'ATXHeading1')).toHaveLength(0); // heading swallowed while open
    const insertAt = s1.doc.toString().indexOf('\n\n# heading') + 1;
    const s2 = s1.update({ changes: { from: insertAt, insert: '$$\n' } }).state;
    ensureSyntaxTree(s2, s2.doc.length, 5000);
    expect(nodesOf(s2, 'DisplayMathMark')).toHaveLength(2);
    expect(nodesOf(s2, 'ATXHeading1')).toHaveLength(1);
  });

  it('handles the degenerate `$$` as the only/last line', () => {
    const lone = makeState('$$');
    expect(nodesOf(lone, 'DisplayMath')).toEqual([{ from: 0, to: 2 }]);
    const tail = makeState('text\n\n$$');
    expect(nodesOf(tail, 'DisplayMath')).toEqual([{ from: 6, to: 8 }]);
  });

  it('claims an unclosed inline-style block ($$x\\n…) up to the next blank line', () => {
    // Pandoc allows no blank line between the `$$` delimiters.
    const state = makeState('$$a+b\nmore\n\n# heading');
    const blocks = nodesOf(state, 'DisplayMath');
    expect(blocks).toHaveLength(1);
    expect(state.sliceDoc(blocks[0].from, blocks[0].to)).toBe('$$a+b\nmore');
    expect(nodesOf(state, 'DisplayMathMark')).toHaveLength(1);
    expect(nodesOf(state, 'ATXHeading1')).toHaveLength(1);
  });
});

// ---------------------------------------------------------------------------
// Inline-style `$$` blocks must close on their own line or stop at a blank
// line. A single-line block with a Quarto label, or a `$$x$$` followed by
// prose, used to fall through to the multi-line scan and swallow every line
// down to the next one ending in `$$` — headings and the next equation with it.
// ---------------------------------------------------------------------------

describe('inline-style $$ block bounds', () => {
  it('closes a single-line labelled block on its own line', () => {
    const state = makeState('$$ E = mc^2 $$ {#eq-mc2}\n\n# heading\n\n$$ a $$');
    const blocks = nodesOf(state, 'DisplayMath');
    expect(blocks.map((b) => state.sliceDoc(b.from, b.to))).toEqual([
      '$$ E = mc^2 $$ {#eq-mc2}',
      '$$ a $$',
    ]);
    const marks = nodesOf(state, 'DisplayMathMark');
    expect(marks).toHaveLength(4);
    expect(state.sliceDoc(marks[0].to, marks[1].from)).toBe(' E = mc^2 ');
    expect(nodesOf(state, 'ATXHeading1')).toHaveLength(1);
  });

  it('leaves `$$x$$` followed by prose to the paragraph', () => {
    const state = makeState('$$x$$.\n\n# heading\n\n$$ a $$');
    expect(nodesOf(state, 'DisplayMath').map((b) => state.sliceDoc(b.from, b.to))).toEqual([
      '$$ a $$',
    ]);
    expect(nodesOf(state, 'InlineDisplayMath')).toEqual([{ from: 0, to: 5 }]);
    expect(nodesOf(state, 'ATXHeading1')).toHaveLength(1);
  });

  it('keeps a wrapped `$$x$$ …` line inside the paragraph above it', () => {
    const state = makeState('so that\n$$x$$ holds.');
    expect(nodesOf(state, 'Paragraph')).toEqual([{ from: 0, to: state.doc.length }]);
    expect(nodesOf(state, 'InlineDisplayMath')).toHaveLength(1);
  });

  it('closes a multi-line block on a labelled `… $$ {#eq-…}` line', () => {
    const state = makeState('$$ a +\nb $$ {#eq-ab}\n\n# heading');
    const [block] = nodesOf(state, 'DisplayMath');
    expect(state.sliceDoc(block.from, block.to)).toBe('$$ a +\nb $$ {#eq-ab}');
    const marks = nodesOf(state, 'DisplayMathMark');
    expect(marks).toHaveLength(2);
    expect(state.sliceDoc(marks[1].from, marks[1].to)).toBe('$$');
    expect(nodesOf(state, 'ATXHeading1')).toHaveLength(1);
  });

  it('stops a multi-line block at a blank line instead of reaching the next equation', () => {
    const state = makeState('$$ a +\nb\n\n# heading\n\n$$ c $$');
    const blocks = nodesOf(state, 'DisplayMath');
    expect(blocks.map((b) => state.sliceDoc(b.from, b.to))).toEqual(['$$ a +\nb', '$$ c $$']);
    expect(nodesOf(state, 'ATXHeading1')).toHaveLength(1);
  });

  it('closes once the blank line is typed over (incremental)', () => {
    const s1 = makeState('$$ a +\nb\n\ntext');
    const blank = s1.doc.line(3).from;
    const s2 = s1.update({ changes: { from: blank, insert: 'c $$' } }).state;
    ensureSyntaxTree(s2, s2.doc.length, 5000);
    const [block] = nodesOf(s2, 'DisplayMath');
    expect(s2.sliceDoc(block.from, block.to)).toBe('$$ a +\nb\nc $$');
    expect(nodesOf(s2, 'DisplayMathMark')).toHaveLength(2);
  });

  it('numbers a single-line labelled block', () => {
    const view = mdView('$$ E = mc^2 $$ {#eq-mc2}\n\nafter', { ensureTree: true, cursor: 'end' });
    const block = view.dom.querySelector('.cm-math-display');
    expect(block).not.toBeNull();
    expect(block!.querySelector('.cm-eq-number')?.textContent).toBe('(1)');
    expect(block!.querySelector('.cm-eq-id')?.textContent).toBe('eq-mc2');
    view.destroy();
  });
});

describe('unclosed $$ rendering', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  // The suite's own beforeEach clears the body; the caret dispatch forces the
  // decoration StateFields to rebuild against the full tree.
  const mountMd = (doc: string) => mdView(doc, { clearBody: false, ensureTree: true, cursor: 0 });

  it('renders no widget and no preview for an unclosed block', () => {
    const view = mountMd('intro\n\n$$\nx+1\n\n# heading');
    expect(view.dom.querySelector('.cm-math-display')).toBeNull();
    expect(view.dom.querySelector('.cm-math-preview')).toBeNull();
    expect(view.dom.querySelector('.cm-content')!.textContent).toContain('# heading');
    view.destroy();
  });

  it('still renders the widget once the block is closed', () => {
    const view = mountMd('intro\n\n$$\nx+1\n$$\n\nafter');
    expect(view.dom.querySelector('.cm-math-display')).not.toBeNull();
    view.destroy();
  });
});

// ---------------------------------------------------------------------------
// CM6's background parse stops about 100k characters past the viewport, so a
// long document never gets a complete tree. The caret must still reveal math
// against the partial one.
// ---------------------------------------------------------------------------

describe('display math before the parse completes', () => {
  it('reveals the block under the caret', () => {
    const filler = Array.from({ length: 2000 }, (_, i) => `line ${i} of prose`).join('\n');
    const doc = 'intro\n\n$$\nx = y\n$$\n\nafter\n\n' + filler;
    document.body.innerHTML = '';
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const view = createEditor(parent, doc, { onContentChange: () => {} }, 'md');
    view.dispatch({ selection: { anchor: 1 } });
    expect(syntaxTreeAvailable(view.state)).toBe(false);
    expect(view.dom.querySelector('.cm-math-display')).not.toBeNull();
    view.dispatch({ selection: { anchor: doc.indexOf('x = y') } });
    expect(view.dom.querySelector('.cm-math-preview')).not.toBeNull();
    expect(view.dom.querySelector('.cm-math-display:not(.cm-math-preview)')).toBeNull();
    view.destroy();
  });
});

// ---------------------------------------------------------------------------
// Labelled display equations — a Quarto `$$ … $$ {#eq-ols}` close line must
// close the block (previously it ran to EOF and rendered nothing), and the
// extracted latex must exclude the trailing attribute.
// ---------------------------------------------------------------------------

describe('labelled $$ … $$ {#eq-…}', () => {
  it('closes on an attributed close line and keeps two marks', () => {
    const state = makeState('$$\ny = x\n$$ {#eq-ols}\n\n# after');
    expect(nodesOf(state, 'DisplayMath')).toHaveLength(1);
    expect(nodesOf(state, 'DisplayMathMark')).toHaveLength(2);
    expect(nodesOf(state, 'ATXHeading1')).toHaveLength(1); // block did close
  });

  it('the closing mark covers only the $$, node spans through the label', () => {
    const state = makeState('$$\ny = x\n$$ {#eq-ols}');
    const [block] = nodesOf(state, 'DisplayMath');
    expect(state.sliceDoc(block.from, block.to)).toBe('$$\ny = x\n$$ {#eq-ols}');
    const marks = nodesOf(state, 'DisplayMathMark');
    expect(state.sliceDoc(marks[1].from, marks[1].to)).toBe('$$'); // not the {#…}
    // Latex strictly between the marks excludes the attribute.
    expect(state.sliceDoc(marks[0].to, marks[1].from).trim()).toBe('y = x');
  });

  it('renders a numbered display widget for a labelled block', () => {
    document.body.innerHTML = '';
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const view = parsed(createEditor(parent, '$$\ny = x\n$$ {#eq-ols}\n\nafter', { onContentChange: () => {} }, 'md'));
    ensureSyntaxTree(view.state, view.state.doc.length, 5000);
    view.dispatch({ selection: { anchor: view.state.doc.length } });
    const num = view.dom.querySelector('.cm-eq-number');
    expect(num).not.toBeNull();
    expect(num!.textContent).toBe('(1)');
    view.destroy();
  });

  it('leaves an unlabelled block unnumbered', () => {
    document.body.innerHTML = '';
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const view = parsed(createEditor(parent, '$$\ny = x\n$$\n\nafter', { onContentChange: () => {} }, 'md'));
    ensureSyntaxTree(view.state, view.state.doc.length, 5000);
    view.dispatch({ selection: { anchor: view.state.doc.length } });
    expect(view.dom.querySelector('.cm-math-display')).not.toBeNull();
    expect(view.dom.querySelector('.cm-eq-number')).toBeNull();
    view.destroy();
  });
});

// ---------------------------------------------------------------------------
// Inline $…$ Pandoc guards — currency must stay prose. Opening $ must be
// followed by non-space; closing $ must be preceded by non-space and not
// followed by a digit. An invalid closer fails the whole attempt (fail-fast);
// Lezer re-invokes the parser at each later `$`, so exactly the valid span
// matches.
// ---------------------------------------------------------------------------

describe('inline $…$ guards', () => {
  it('does not turn currency into math', () => {
    expect(nodesOf(makeState('I paid $5 for $10'), 'InlineMath')).toHaveLength(0);
    expect(nodesOf(makeState('$20,000 and $30,000'), 'InlineMath')).toHaveLength(0);
  });

  it('rejects space-adjacent delimiters and digit-following closers', () => {
    expect(nodesOf(makeState('$ x$'), 'InlineMath')).toHaveLength(0);
    expect(nodesOf(makeState('$x $'), 'InlineMath')).toHaveLength(0);
    expect(nodesOf(makeState('$x$2'), 'InlineMath')).toHaveLength(0);
  });

  it('still parses ordinary inline math', () => {
    const a = makeState('a $x$ b');
    expect(nodesOf(a, 'InlineMath')).toEqual([{ from: 2, to: 5 }]);
    const b = makeState('$x$ 2');
    expect(nodesOf(b, 'InlineMath')).toEqual([{ from: 0, to: 3 }]);
    const c = makeState('hello $x^2$ world');
    expect(nodesOf(c, 'InlineMath')).toHaveLength(1);
  });

  it('matches exactly the valid span when a currency $ precedes it', () => {
    const state = makeState('price $5, cost $x$');
    const nodes = nodesOf(state, 'InlineMath');
    expect(nodes).toHaveLength(1);
    expect(state.sliceDoc(nodes[0].from, nodes[0].to)).toBe('$x$');
  });

  it('ignores escaped \\$ and parses the real span', () => {
    const state = makeState('\\$5 and $x^2$');
    const nodes = nodesOf(state, 'InlineMath');
    expect(nodes).toHaveLength(1);
    expect(state.sliceDoc(nodes[0].from, nodes[0].to)).toBe('$x^2$');
  });
});

// ---------------------------------------------------------------------------
// Blockquoted display math (audit H-1). The close-line regex used to run
// against the full line text (`> $$`), never matched, and the unclosed
// EOF-claim swallowed the whole document below a blockquoted equation.
// ---------------------------------------------------------------------------

describe('display math inside blockquotes', () => {
  it('closes a > $$ block and leaves the document below intact', () => {
    const state = makeState('> $$\n> E = mc^2\n> $$\n\npara after\n\n# heading');
    const blocks = nodesOf(state, 'DisplayMath');
    expect(blocks).toHaveLength(1);
    expect(nodesOf(state, 'DisplayMathMark')).toHaveLength(2);
    // The block must end inside the quote, not swallow the heading.
    const quoteEnd = state.doc.toString().indexOf('\n\npara');
    expect(blocks[0].to).toBeLessThanOrEqual(quoteEnd);
    expect(nodesOf(state, 'ATXHeading1')).toHaveLength(1);
  });

  it('closes inside nested > > quotes', () => {
    const state = makeState('> > $$\n> > x+1\n> > $$\n\ntail');
    expect(nodesOf(state, 'DisplayMathMark')).toHaveLength(2);
    expect(nodesOf(state, 'Paragraph').length).toBeGreaterThan(0);
  });

  it('closes on a lazy (unprefixed) continuation line', () => {
    const state = makeState('> $$\n> x+1\n$$\n\n# after');
    expect(nodesOf(state, 'DisplayMathMark')).toHaveLength(2);
    expect(nodesOf(state, 'ATXHeading1')).toHaveLength(1);
  });
});

// Harness follow-up: the quote markers themselves must not leak into the
// rendered LaTeX (they painted as stray > operators).
describe('blockquote marker stripping in extracted latex', () => {
  it('renders quoted display math without > in the KaTeX output', () => {
    // Full-editor mount: latexBetweenMarks feeds the widget.
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const view = parsed(createEditor(
      parent,
      '> $$\n> E = mc^2\n> $$\n\ntail',
      { onContentChange: () => {} },
      'md',
    ));
    ensureSyntaxTree(view.state, view.state.doc.length, 5000);
    // Move caret to tail so the block renders as a widget.
    view.dispatch({ selection: { anchor: view.state.doc.length } });
    const widget = view.dom.querySelector('.cm-math-rendered.cm-math-display');
    expect(widget).not.toBeNull();
    const annotation = widget!.querySelector('annotation');
    expect(annotation?.textContent ?? '').toBe('E = mc^2');
    view.destroy();
    parent.remove();
  });

  it('keeps a genuine leading > in unquoted math', () => {
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const view = parsed(createEditor(
      parent,
      '$$\n> x\n$$\n\ntail',
      { onContentChange: () => {} },
      'md',
    ));
    ensureSyntaxTree(view.state, view.state.doc.length, 5000);
    view.dispatch({ selection: { anchor: view.state.doc.length } });
    const annotation = view.dom.querySelector(
      '.cm-math-display annotation',
    );
    expect(annotation?.textContent ?? '').toContain('> x');
    view.destroy();
    parent.remove();
  });
});
