import { describe, it, expect, afterEach } from 'vitest';
import type { EditorView } from '@codemirror/view';
import { destroyViews, texView } from './helpers/views';

const mount = (doc: string, viewMode: 'preview' | 'mixed'): EditorView =>
  texView(doc, { viewMode, cursor: 'end' });

afterEach(destroyViews);

const text = (view: EditorView): string =>
  view.dom.querySelector('.cm-content')!.textContent ?? '';
const texts = (view: EditorView, cls: string): string[] =>
  Array.from(view.dom.querySelectorAll(`.${cls}`)).map((el) => el.textContent ?? '');

const DOC = '\\begin{enumerate}\n\\item alpha\n\\item[custom] beta\n\\end{enumerate}\nafter';

describe('mixed: LaTeX lists', () => {
  it('keeps the fences as dimmed source', () => {
    const view = mount(DOC, 'mixed');
    expect(text(view)).toContain('\\begin{enumerate}');
    expect(text(view)).toContain('\\end{enumerate}');
    expect(texts(view, 'cm-syntax-dim')).toEqual(['\\begin{enumerate}', '\\end{enumerate}']);
  });

  it('keeps \\item as source in the marker color, no widget', () => {
    const view = mount(DOC, 'mixed');
    expect(text(view)).toContain('\\item alpha');
    expect(text(view)).toContain('\\item[custom] beta');
    expect(view.dom.querySelector('.cm-tex-item-marker')).toBeNull();
    expect(texts(view, 'cm-tex-item-source')).toEqual(['\\item', '\\item']);
  });

  it('preview still renders markers (control)', () => {
    const view = mount(DOC, 'preview');
    expect(texts(view, 'cm-tex-item-marker').length).toBe(2);
    expect(text(view)).not.toContain('\\begin{enumerate}');
  });
});
