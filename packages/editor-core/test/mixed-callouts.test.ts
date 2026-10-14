import { describe, it, expect, afterEach } from 'vitest';
import type { EditorView } from '@codemirror/view';
import type { Language } from '../src/editor/setup';
import { destroyViews, langView } from './helpers/views';

/**
 * Mixed view mode, callouts (both surface syntaxes): every row from the open
 * fence to the close fence carries the box classes, the fences stay as dimmed
 * source, the synthesized number floats as a `data-callout` chip on the top
 * row (no caret surface, no extra row: the slide-number mechanism), and the
 * title argument keeps the label's styling in place.
 */
const mount = (doc: string, language: Language, viewMode: 'preview' | 'mixed'): EditorView =>
  langView(doc, language, { viewMode, cursor: 'end' });

afterEach(destroyViews);

const text = (view: EditorView): string =>
  view.dom.querySelector('.cm-content')!.textContent ?? '';
const calloutRows = (view: EditorView): HTMLElement[] =>
  Array.from(view.dom.querySelectorAll('.cm-line.cm-callout'));
const top = (view: EditorView): HTMLElement | null =>
  view.dom.querySelector('.cm-line.cm-callout-top');

const MD_THM = '::: {#thm-pyth name="Pythagoras"}\nbody\n:::\nafter';
const MD_PROOF = '::: {.proof}\nbody\n:::\nafter';
const TEX_THM = '\\begin{theorem}[Pythagoras]\nbody\n\\end{theorem}\nafter';
const TEX_BLOCK = '\\documentclass{beamer}\n\\begin{block}{Key point}\nbody\n\\end{block}\nafter';

describe('mixed: markdown callouts', () => {
  it('keeps both fences as rows inside the box', () => {
    const view = mount(MD_THM, 'md', 'mixed');
    expect(calloutRows(view)).toHaveLength(3);
    expect(text(view)).toContain('::: {#thm-pyth name="Pythagoras"}');
    expect(text(view)).toContain(':::after');
    expect(view.dom.querySelector('.cm-callout-label')).toBeNull();
  });

  it('floats the label and number as a chip on the top row', () => {
    const view = mount(MD_THM, 'md', 'mixed');
    expect(top(view)?.dataset.callout).toBe('Theorem 1');
    const bottom = view.dom.querySelector('.cm-line.cm-callout-bottom');
    expect(bottom?.textContent).toBe(':::');
  });

  it('dims the fence text', () => {
    const view = mount(MD_THM, 'md', 'mixed');
    const dims = Array.from(view.dom.querySelectorAll('.cm-syntax-dim')).map((e) => e.textContent);
    expect(dims).toContain(':::');
  });

  it('marks the title argument with the title styling', () => {
    const view = mount(MD_THM, 'md', 'mixed');
    expect(view.dom.querySelector('.cm-callout-title')?.textContent).toBe('Pythagoras');
  });

  it('an unnumbered type has no chip', () => {
    const view = mount(MD_PROOF, 'md', 'mixed');
    expect(top(view)?.dataset.callout).toBeUndefined();
  });

  it('preview still collapses the fences into the label widget (control)', () => {
    const view = mount(MD_THM, 'md', 'preview');
    expect(view.dom.querySelector('.cm-callout-label')?.textContent).toContain('Theorem 1');
    expect(top(view)?.dataset.callout).toBeUndefined();
  });

  it('the caret on the open fence changes nothing', () => {
    const view = mount(MD_THM, 'md', 'mixed');
    const before = view.dom.querySelector('.cm-content')!.innerHTML;
    view.dispatch({ selection: { anchor: 2 } });
    expect(view.dom.querySelector('.cm-content')!.innerHTML).toBe(before);
  });
});

describe('mixed: markdown callouts, title anchoring', () => {
  it('marks the title after name=", not a same-text substring inside the id', () => {
    // The id slug ("thm-abc") contains the same text as the title ("abc"):
    // the title mark must land on the SECOND "abc", inside name="abc".
    const doc = '::: {#thm-abc name="abc"}\nbody\n:::\nafter';
    const view = mount(doc, 'md', 'mixed');
    const mark = view.dom.querySelector('.cm-callout-title');
    expect(mark?.textContent).toBe('abc');
    const nameAttrIdx = doc.indexOf('name="') + 'name="'.length;
    const from = view.state.doc.line(1).from + doc.indexOf('abc', nameAttrIdx);
    expect(view.posAtDOM(mark!)).toBe(from);
  });
});

describe('mixed: LaTeX callouts', () => {
  it('keeps both fences and floats the chip', () => {
    const view = mount(TEX_THM, 'tex', 'mixed');
    expect(calloutRows(view)).toHaveLength(3);
    expect(text(view)).toContain('\\begin{theorem}[Pythagoras]');
    expect(text(view)).toContain('\\end{theorem}');
    expect(top(view)?.dataset.callout).toBe('Theorem 1');
    expect(view.dom.querySelector('.cm-callout-title')?.textContent).toBe('Pythagoras');
  });

  it('a beamer block styles its brace title as the label and has no chip', () => {
    const view = mount(TEX_BLOCK, 'tex', 'mixed');
    expect(view.dom.querySelector('.cm-callout-label')?.textContent).toBe('Key point');
    expect(top(view)?.dataset.callout).toBeUndefined();
  });
});
