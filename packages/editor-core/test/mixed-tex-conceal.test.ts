import { describe, it, expect, afterEach } from 'vitest';
import type { EditorView } from '@codemirror/view';
import { destroyViews, texView } from './helpers/views';
import { probeHidden } from '../src/debug-probe';

/**
 * Mixed view mode, LaTeX inline commands: `\cmd{` and the closing `}` get the
 * `cm-syntax-dim` mark instead of being hidden, no widgets render (no
 * section-number pill, no ref/cite/label pill), and the argument text keeps
 * whatever styling texDecorationsPlugin already gives it.
 */
const mount = (doc: string, viewMode: 'preview' | 'mixed'): EditorView =>
  texView(doc, { viewMode, cursor: 'end' });

afterEach(destroyViews);

const text = (view: EditorView): string =>
  view.dom.querySelector('.cm-content')!.textContent ?? '';
const texts = (view: EditorView, cls: string): string[] =>
  Array.from(view.dom.querySelectorAll(`.${cls}`)).map((el) => el.textContent ?? '');

describe('mixed: LaTeX inline commands', () => {
  it('dims \\emph{ and } and keeps the argument styled', () => {
    const view = mount('a \\emph{word} b', 'mixed');
    expect(text(view)).toContain('\\emph{word}');
    expect(texts(view, 'cm-tex-em')).toEqual(['word']);
    expect(texts(view, 'cm-syntax-dim')).toEqual(['\\emph{', '}']);
  });

  it('dims \\section{ and }, no section-number widget', () => {
    const previewControl = mount('\\section{Intro}\nbody', 'preview');
    expect(previewControl.dom.querySelector('.cm-tex-secnum')).not.toBeNull();

    const view = mount('\\section{Intro}\nbody', 'mixed');
    expect(text(view)).toContain('\\section{Intro}');
    expect(view.dom.querySelector('.cm-tex-secnum')).toBeNull();
    expect(texts(view, 'cm-syntax-dim')).toEqual(['\\section{', '}']);
  });

  it('keeps \\ref{eq:1} as source, no pill', () => {
    const view = mount('see \\ref{eq:1} here', 'mixed');
    expect(text(view)).toContain('\\ref{eq:1}');
    expect(view.dom.querySelector('.cm-tex-label-pill')).toBeNull();
    expect(view.dom.querySelector('.cm-tex-ref-pill')).toBeNull();
    expect(texts(view, 'cm-syntax-dim')).toEqual(['\\ref{', '}']);
  });

  it('\\href keeps the live-link mark on the display text and dims the rest', () => {
    const view = mount('\\href{https://x.y}{text} tail', 'mixed');
    const link = view.dom.querySelector('.cm-live-link');
    expect(link?.textContent).toBe('text');
    expect(link?.getAttribute('data-url')).toBe('https://x.y');
    expect(text(view)).toContain('\\href{https://x.y}{text}');
  });

  it('a Preview control still hides \\emph{ (byte-identical Preview path)', () => {
    const view = mount('a \\emph{word} b', 'preview');
    expect(text(view)).not.toContain('\\emph{');
    expect(text(view)).toContain('word');
  });

  it('every hidden range in Mixed lies inside the math span', () => {
    const doc = 'let $a+b$ and \\emph{x} tail';
    const view = mount(doc, 'mixed');
    const mathFrom = doc.indexOf('$a+b$');
    const mathTo = mathFrom + '$a+b$'.length;
    const hidden = probeHidden(view);
    for (const h of hidden) {
      expect(h.from).toBeGreaterThanOrEqual(mathFrom);
      expect(h.to).toBeLessThanOrEqual(mathTo);
    }
  });
});
