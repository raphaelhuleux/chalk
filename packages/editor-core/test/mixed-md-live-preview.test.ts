import { describe, it, expect, afterEach } from 'vitest';
import type { EditorView } from '@codemirror/view';
import { probeHidden } from '../src/debug-probe';
import { destroyViews, mdView } from './helpers/views';

/**
 * Mixed view mode, markdown inline constructs: the delimiters stay visible as
 * dimmed syntax, the content keeps its styling, and nothing reveals because
 * nothing is hidden. Images are the exception (replaced whole, reveal on
 * caret, exactly as in Preview).
 */
const mount = (doc: string, viewMode: 'preview' | 'mixed'): EditorView =>
  mdView(doc, { viewMode, cursor: 'end' });

afterEach(destroyViews);

const text = (view: EditorView): string =>
  view.dom.querySelector('.cm-content')!.textContent ?? '';
const texts = (view: EditorView, cls: string): string[] =>
  Array.from(view.dom.querySelectorAll(`.${cls}`)).map((el) => el.textContent ?? '');

describe('mixed: inline markdown', () => {
  it('bold keeps its stars, dimmed, and its weight', () => {
    const view = mount('a **bold** b\ntail', 'mixed');
    expect(text(view)).toContain('**bold**');
    expect(texts(view, 'cm-live-bold')).toEqual(['bold']);
    expect(texts(view, 'cm-syntax-dim')).toEqual(['**', '**']);
  });

  it('preview still hides the stars (control)', () => {
    const view = mount('a **bold** b\ntail', 'preview');
    expect(text(view)).not.toContain('**');
    expect(texts(view, 'cm-live-bold')).toEqual(['bold']);
  });

  it('preview hides every marked construct\'s delimiters and classes its content', () => {
    const view = mount('**b** *i* ~~s~~ ==h== `c` **x *y* z**\ntail', 'preview');
    expect(text(view)).toContain('b i s h c x *y* z');
    expect(texts(view, 'cm-live-bold')).toEqual(['b']);
    expect(texts(view, 'cm-live-italic')).toEqual(['i']);
    expect(texts(view, 'cm-live-strikethrough')).toEqual(['s']);
    expect(texts(view, 'cm-live-highlight')).toEqual(['h']);
    expect(texts(view, 'cm-live-code')).toEqual(['c']);
    // Bold wrapping italic takes the combined class (the nested run is not
    // walked, so its own stars stay).
    expect(texts(view, 'cm-live-bold-italic')).toEqual(['x *y* z']);
  });

  it('italic, strikethrough, highlight and code show their marks', () => {
    const view = mount('*i* ~~s~~ ==h== `c`\ntail', 'mixed');
    expect(text(view)).toContain('*i* ~~s~~ ==h== `c`');
    expect(texts(view, 'cm-live-italic')).toEqual(['i']);
    expect(texts(view, 'cm-live-strikethrough')).toEqual(['s']);
    expect(texts(view, 'cm-live-highlight')).toEqual(['h']);
    expect(texts(view, 'cm-live-code')).toEqual(['c']);
  });

  it('a link shows its brackets and target and keeps the link styling', () => {
    const view = mount('see [chalk](https://example.com) now\ntail', 'mixed');
    expect(text(view)).toContain('[chalk](https://example.com)');
    expect(texts(view, 'cm-live-link')).toEqual(['chalk']);
  });

  it('a heading keeps its trailing Quarto id visible', () => {
    const view = mount('# Setup {#sec-setup}\ntail', 'mixed');
    expect(text(view)).toContain('{#sec-setup}');
    expect(view.dom.querySelector('.cm-md-label-pill')).toBeNull();
  });

  it('an image is still replaced, and it is the only hidden range', () => {
    const doc = 'a **b** ![alt](pic.png) c\ntail';
    const view = mount(doc, 'mixed');
    expect(text(view)).not.toContain('![alt]');
    expect(view.dom.querySelector('.cm-live-image')).not.toBeNull();
    const imgFrom = doc.indexOf('![alt]');
    const imgTo = imgFrom + '![alt](pic.png)'.length;
    const hidden = probeHidden(view);
    expect(hidden.length).toBeGreaterThan(0);
    for (const h of hidden) {
      expect(h.from).toBeGreaterThanOrEqual(imgFrom);
      expect(h.to).toBeLessThanOrEqual(imgTo);
    }
  });

  it('the caret inside bold changes nothing (no reveal, no reflow)', () => {
    const doc = 'a **bold** b\ntail';
    const view = mount(doc, 'mixed');
    const before = view.dom.querySelector('.cm-content')!.innerHTML;
    view.dispatch({ selection: { anchor: doc.indexOf('bold') + 2 } });
    expect(view.dom.querySelector('.cm-content')!.innerHTML).toBe(before);
  });
});
