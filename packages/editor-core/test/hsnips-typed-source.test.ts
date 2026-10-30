import { describe, it, expect, beforeAll } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { EditorView } from '@codemirror/view';
import { EditorState, EditorSelection } from '@codemirror/state';
import { parseHSnips } from '../src/editor/hsnips-parser';
import { hsnipsExtension, hsnipsKeymap, setSnippets, _testing } from '../src/editor/hsnips-plugin';
import { mdView, texView } from './helpers/views';

/**
 * The bundled set, typed one key at a time. Reachability is covered by
 * hsnips-bundled-conflicts; this pins the opposite failure: a snippet firing
 * on text that was never meant as its trigger.
 */
const snippets = parseHSnips(readFileSync(join(__dirname, '../assets/latex.hsnips'), 'utf8'));

beforeAll(() => {
  Range.prototype.getClientRects = () => [] as unknown as DOMRectList;
  Range.prototype.getBoundingClientRect = () =>
    ({ x: 0, y: 0, width: 0, height: 0, top: 0, right: 0, bottom: 0, left: 0, toJSON: () => ({}) }) as DOMRect;
});

function typeOne(view: EditorView, ch: string): void {
  const pos = view.state.selection.main.head;
  view.dispatch({
    changes: { from: pos, to: pos, insert: ch },
    selection: EditorSelection.cursor(pos + 1),
    userEvent: 'input.type',
  });
}

function typeInto(view: EditorView, text: string): string {
  for (const ch of text) typeOne(view, ch);
  const doc = view.state.doc.toString();
  view.destroy();
  return doc;
}

function typed(text: string, math: boolean, language: 'tex' | 'md' = 'tex'): string {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  const view = new EditorView({
    state: EditorState.create({
      extensions: [hsnipsExtension({ isInMathContext: () => math, language })],
    }),
    parent,
  });
  view.dispatch({ effects: setSnippets.of(snippets) });
  return typeInto(view, text);
}

describe('hand-typed LaTeX stays as typed', () => {
  it.each([
    '\\alpha', '\\beta', '\\zeta', '\\theta', '\\eta', '\\epsilon', '\\varepsilon', '\\phi',
    '\\pi', '\\psi', '\\tau', '\\sum', '\\prod', '\\partial', '\\setminus', '\\subset',
    '\\supset', '\\cap', '\\in', '\\int', '\\lim', '\\mathbf', '\\mathrm', '\\rm', '\\text',
    '\\left(', '\\rightarrow', '\\cdot', '\\pmod', '\\bmod', '\\det', '\\hat', '\\bar',
    '\\vec', '\\dot', '\\ddot', '\\tilde', '\\sqrt', '\\sin', '\\log', '\\max', '\\inf',
    '\\begin{pmatrix}', '\\end{cases}', '\\label{eq:sum}', '\\ref{eq:set_a1}',
  ])('%s', (src) => {
    expect(typed(src, true)).toBe(src);
  });
});

describe('math triggers', () => {
  it.each([
    ['beta', 'beta'],
    ['theta', 'theta'],
    ['epsilon', 'epsilon'],
    ['pi', 'pi'],
    ['2;p', '2\\pi'],
    [';th', '\\theta'],
    [';ta', '\\tau'],
    [';b', '\\beta'],
    ['sin', '\\sin'],
    ['sinh', '\\sinh'],
    ['arcsin', '\\arcsin'],
    ['max', '\\max'],
    ['infty', '\\infty'],
    ['argmax', '\\arg\\max'],
    ['supset', '\\supset'],
    [';p', '\\pi'],
    [';f', '\\phi'],
    [';vp', '\\varphi'],
    ['x^^', 'x^{}'],
    ['==', '&=  \\\\\n'],
    ['eqv', '\\equiv'],
    ['bf', '\\mathbf{}'],
    ['x->y', 'x\\toy'],
    ['x!=y', 'x\\neqy'],
    ['x**y', 'x\\cdoty'],
    ['(cap', '(\\cap'],
    ['(int', '(\\int  \\, d'],
    ['<->', '\\leftrightarrow'],
    ['<-->', '\\longleftrightarrow'],
    ['<=>', '\\Leftrightarrow'],
    ['<==>', '\\Longleftrightarrow'],
    ['ubr', '\\underbrace{}_{}'],
    ['obr', '\\overbrace{}^{}'],
    ['\\underbrace', '\\underbrace'],
    ['pmat', 'pmat'],
    ['pmat22', '\\begin{pmatrix}\n &  \\\\\n & \n\\end{pmatrix}'],
    ['bmat13', '\\begin{bmatrix}\n &  & \n\\end{bmatrix}'],
    ['mat21', '\\begin{matrix}\n \\\\\n\n\\end{matrix}'],
    ['Vmat11', '\\begin{Vmatrix}\n\n\\end{Vmatrix}'],
    ['x,.', '\\mathbf{x}'],
    ['x,,', '\\boldsymbol{x}'],
    ['x__', 'x_{}'],
    ['x^', 'x^'],
    ['K_t', 'K_t'],
    [';asr', '\\alpha^{2}'],
    [';ahat', '\\hat{\\alpha}'],
    ['\\alpha sr', '\\alpha^{2}'],
    ['RR', '\\mathbb{R}'],
    ['QQ', '\\mathbb{Q}'],
    ['EE', '\\mathbb{E}'],
    ['Lcal', '\\mathcal{L}'],
    ['+-', '\\pm'],
    ['cdot', '\\cdot'],
    ['iint', '\\iint'],
    ['part', '\\partial'],
  ])('%s', (src, want) => {
    expect(typed(src, true)).toBe(want);
  });

  it('leaves double differentials alone until Tab', () => {
    expect(typed('dxdy', true)).toBe('dxdy');
  });
});

describe('prose triggers', () => {
  it.each(['balance', 'ballot', 'admin'])('%s stays', (src) => {
    expect(typed(src, false)).toBe(src);
  });

  it('`;` keys open structures outside math and symbols inside it', () => {
    expect(typed(';a', true)).toBe('\\alpha');
    expect(typed(';a', false)).toContain('\\begin{align}');
    expect(typed(';d', true)).toBe('\\delta');
    expect(typed(';f', false)).toContain('\\begin{figure}');
  });

  it('display math follows the language', () => {
    expect(typed('dm', false, 'tex')).toBe('\\[\n\n\\]');
    expect(typed('dm', false, 'md')).toBe('$$\n\n$$');
    expect(typed('mk', false, 'md')).toBe('$$');
  });

  it('LaTeX-only structures stay out of markdown', () => {
    expect(typed(';s', false, 'md')).toBe(';s');
    expect(typed(';s', false, 'tex')).toContain('\\section{');
  });

  it('mounted markdown keeps code out of it', () => {
    const load = (view: EditorView) => {
      view.dispatch({ effects: setSnippets.of(snippets) });
      return view;
    };
    expect(typeInto(load(mdView('`a`', { cursor: 2 })), 'mkdir')).toBe('`amkdir`');
    expect(typeInto(load(mdView('```\n\n```', { cursor: 4 })), 'mkdir')).toBe('```\nmkdir\n```');
  });
});

it('is wired through the real tex setup', () => {
  const view = texView('');
  view.dispatch({ effects: setSnippets.of(snippets) });
  expect(typeInto(view, 'dm')).toBe('\\[\n\n\\]');
});

it('Tab walks a sized matrix cell by cell', () => {
  const view = texView('$$', { cursor: 1 });
  view.dispatch({ effects: setSnippets.of(snippets) });
  const tab = hsnipsKeymap[0].run!;
  for (const ch of 'pmat22') typeOne(view, ch);
  for (const cell of ['a', 'b', 'c', 'd']) {
    typeOne(view, cell);
    tab(view);
  }
  expect(view.state.doc.toString()).toBe('$\\begin{pmatrix}\na & b \\\\\nc & d\n\\end{pmatrix}$');
  expect(view.state.selection.main.head).toBe(view.state.doc.length - 1);
  view.destroy();
});

it('plain pmat still expands on Tab', () => {
  const view = texView('$$', { cursor: 1 });
  view.dispatch({ effects: setSnippets.of(snippets) });
  for (const ch of 'pmat') typeOne(view, ch);
  hsnipsKeymap[0].run!(view);
  expect(view.state.doc.toString()).toBe('$\\begin{pmatrix}\n\n\\end{pmatrix}$');
  view.destroy();
});

it('Tab out of a snippet ends it, so later typing is not a highlighted field', () => {
  const view = texView('', { cursor: 0 });
  view.dispatch({ effects: setSnippets.of(snippets) });
  for (const ch of 'mkx') typeOne(view, ch);
  hsnipsKeymap[0].run!(view);
  expect(view.state.field(_testing.sessionField)).toBeNull();
  for (const ch of ' then') typeOne(view, ch);
  expect(view.state.doc.toString()).toBe('$x$ then');
  expect(view.dom.querySelector('.cm-hsnips-placeholder')).toBeNull();
  view.destroy();
});
