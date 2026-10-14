import { describe, it, expect, afterEach } from 'vitest';
import type { EditorView } from '@codemirror/view';
import { destroyViews, mdView } from './helpers/views';

const mount = (doc: string, viewMode: 'preview' | 'mixed'): EditorView =>
  mdView(doc, { viewMode, cursor: 'end' });

afterEach(destroyViews);

const text = (view: EditorView): string =>
  view.dom.querySelector('.cm-content')!.textContent ?? '';

const DOC = '::: {#thm-a}\nbody\n:::\nSee @thm-a and @thm-missing.\ntail';

describe('mixed: cross-references', () => {
  it('a resolved reference shows its key, styled, with no pill', () => {
    const view = mount(DOC, 'mixed');
    expect(text(view)).toContain('@thm-a');
    const key = view.dom.querySelector('.cm-crossref-key');
    expect(key?.textContent).toBe('@thm-a');
  });

  it('an unresolved reference is still marked unresolved', () => {
    const view = mount(DOC, 'mixed');
    expect(view.dom.querySelector('.cm-crossref-unresolved')?.textContent).toBe('@thm-missing');
  });

  it('preview still replaces the resolved reference (control)', () => {
    const view = mount(DOC, 'preview');
    expect(text(view)).not.toContain('@thm-a ');
    expect(view.dom.querySelector('.cm-crossref-key')).toBeNull();
  });
});
