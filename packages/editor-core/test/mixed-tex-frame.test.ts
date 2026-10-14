import { describe, it, expect, afterEach } from 'vitest';
import type { EditorView } from '@codemirror/view';
import { destroyViews, texView } from './helpers/views';

/**
 * Mixed view mode, slide cards. The card and the band stay; the fence rows
 * are dimmed source; the title and subtitle are marked in place with the
 * classes the `\frametitle` form already gets from tex-decorations, so both
 * syntaxes style the same (class parity; a measured height parity is
 * impossible with raw rows, see the plan's spec amendments).
 */
const mount = (doc: string, viewMode: 'preview' | 'mixed'): EditorView =>
  texView(doc, { viewMode, cursor: 'end' });

afterEach(destroyViews);

const text = (view: EditorView): string =>
  view.dom.querySelector('.cm-content')!.textContent ?? '';
const texts = (view: EditorView, cls: string): string[] =>
  Array.from(view.dom.querySelectorAll(`.${cls}`)).map((el) => el.textContent ?? '');
const rows = (view: EditorView, cls: string): HTMLElement[] =>
  Array.from(view.dom.querySelectorAll(`.cm-line.${cls}`));

const BEAMER = '\\documentclass{beamer}\n';
const BRACE = `${BEAMER}\\begin{frame}{Roadmap}{Where next}\nalpha\n\\end{frame}\nafter`;
const COMMAND = `${BEAMER}\\begin{frame}[t]\n\\frametitle{Roadmap}\n\\framesubtitle{Where next}\nalpha\n\\end{frame}\nafter`;

describe('mixed: slide cards', () => {
  it('brace form: the fence row is the band and keeps the slide number', () => {
    const view = mount(BRACE, 'mixed');
    expect(rows(view, 'cm-slide')).toHaveLength(3);
    const top = rows(view, 'cm-slide-top')[0];
    expect(top.dataset.slide).toBe('1');
    expect(top.textContent).toBe('\\begin{frame}{Roadmap}{Where next}');
    expect(rows(view, 'cm-slide-band-end')[0]).toBe(top);
    expect(view.dom.querySelector('.cm-slide-header')).toBeNull();
  });

  it('brace form: title and subtitle are marked in place, the rest dimmed', () => {
    const view = mount(BRACE, 'mixed');
    expect(texts(view, 'cm-tex-frametitle')).toEqual(['Roadmap']);
    expect(texts(view, 'cm-tex-framesubtitle')).toEqual(['Where next']);
    expect(texts(view, 'cm-syntax-dim')).toEqual(['\\begin{frame}{', '}{', '}', '\\end{frame}']);
  });

  it('command form: the fence, title and subtitle rows form the band', () => {
    const view = mount(COMMAND, 'mixed');
    const band = rows(view, 'cm-slide-band');
    expect(band.map((r) => r.textContent)).toEqual([
      '\\begin{frame}[t]',
      '\\frametitle{Roadmap}',
      '\\framesubtitle{Where next}',
    ]);
    expect(rows(view, 'cm-slide-top')[0].textContent).toBe('\\begin{frame}[t]');
    expect(rows(view, 'cm-slide-band-end')[0].textContent).toBe('\\framesubtitle{Where next}');
    expect(texts(view, 'cm-tex-frametitle')).toEqual(['Roadmap']);
    expect(texts(view, 'cm-tex-framesubtitle')).toEqual(['Where next']);
  });

  it('the foot row shows \\end{frame} dimmed', () => {
    const view = mount(BRACE, 'mixed');
    expect(text(view)).toContain('\\end{frame}');
    expect(rows(view, 'cm-slide-bottom')[0].textContent).toBe('\\end{frame}');
  });

  it('body indent is not hidden', () => {
    const view = mount(`${BEAMER}\\begin{frame}{T}\n    alpha\n\\end{frame}\nafter`, 'mixed');
    expect(text(view)).toContain('    alpha');
  });

  it('a title that repeats the keyword marks the argument, not \\begin{frame}', () => {
    // The title text ("frame") also occurs inside the env keyword itself
    // ("\begin{frame}"): the mark must land on the SECOND occurrence, the
    // brace argument, not the keyword.
    const doc = `${BEAMER}\\begin{frame}{frame}\nbody\n\\end{frame}\nafter`;
    const view = mount(doc, 'mixed');
    const mark = view.dom.querySelector('.cm-tex-frametitle');
    expect(mark?.textContent).toBe('frame');
    const openLine = doc.indexOf('\\begin{frame}{frame}');
    const argIdx = doc.indexOf('{frame}', openLine + '\\begin{frame}'.length) + 1;
    expect(view.posAtDOM(mark!)).toBe(argIdx);
  });

  it('preview still replaces the brace fence with the header widget (control)', () => {
    const view = mount(BRACE, 'preview');
    expect(view.dom.querySelector('.cm-slide-header')).not.toBeNull();
    expect(text(view)).not.toContain('\\begin{frame}');
  });
});
