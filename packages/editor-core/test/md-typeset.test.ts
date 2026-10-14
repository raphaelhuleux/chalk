import { describe, it, expect, afterEach } from 'vitest';
import type { EditorView } from '@codemirror/view';
import { defaultEditorConfig } from '../src/editor/theme';
import { markdownTypesetCompartment, markdownTypesetExtension } from '../src/editor/md-typeset';
import { destroyViews, mdView } from './helpers/views';

afterEach(destroyViews);

const typeset = { ...defaultEditorConfig, markdownStyle: 'typeset' as const };
const mount = (doc: string, cursor: number | 'end' = 'end', viewMode: 'preview' | 'mixed' = 'preview') =>
  mdView(doc, { config: { ...typeset, viewMode }, cursor });

const lineText = (view: EditorView, cls: string): string[] =>
  Array.from(view.dom.querySelectorAll(`.${cls}`)).map((el) => el.textContent ?? '');
const markers = (view: EditorView) => lineText(view, 'cm-md-item-mark');
const content = (view: EditorView) => view.dom.querySelector('.cm-content')!.textContent ?? '';
const hangOf = (el: Element) => /--chalk-hang:\s*([^;]+)/.exec(el.getAttribute('style') ?? '')?.[1];

describe('typeset Markdown: headings', () => {
  it('keeps the heading marks visible, as every theme does', () => {
    expect(content(mount('## Setup\n\nbody'))).toContain('## Setup');
  });
});

describe('heading marks carry their own class', () => {
  it('the `#` run is classed in Mixed, so a theme can quiet it', () => {
    const view = mount('## Setup\n\nbody', 'end', 'mixed');
    expect(lineText(view, 'cm-md-header-mark')).toEqual(['## ']);
  });
});

describe('typeset Markdown: lists', () => {
  const LIST = ['- one', '- two that', '  continues', '  - nested', '', '1. first', 'tail'].join('\n');

  it('markers stay their source text, indentation hidden', () => {
    expect(markers(mount(LIST))).toEqual(['- ', '- ', '- ', '1. ']);
  });

  it('every list line hangs by depth in em; continuation indent is hidden', () => {
    const view = mount(LIST);
    const lines = Array.from(view.dom.querySelectorAll('.cm-md-list-line')).map((el) => ({
      text: el.textContent,
      hang: hangOf(el),
      cont: el.classList.contains('cm-md-list-cont'),
    }));
    expect(lines).toContainEqual({ text: 'continues', hang: '1.1em', cont: true });
    expect(lines).toContainEqual({ text: '- nested', hang: '2.2em', cont: false });
  });

  it('a caret on a marker swaps nothing: the marker is text either way', () => {
    expect(markers(mount(LIST, 1))).toEqual(['- ', '- ', '- ', '1. ']);
  });

  it('code inside a list item keeps its source layout', () => {
    const view = mount(['- item', '', '  ```', '  code  here', '  ```', 'tail'].join('\n'));
    expect(content(view)).toContain('code  here');
    for (const el of view.dom.querySelectorAll('.cm-md-list-line')) {
      expect(el.textContent).not.toContain('code');
    }
  });
});

describe('typeset Markdown: quotes', () => {
  it('quote lines get the block class and lose their `> ` off the caret line', () => {
    const view = mount('> quoted text\n\ntail');
    expect(lineText(view, 'cm-md-quote-line')).toEqual(['quoted text']);
  });
});

describe('typeset Markdown is opt-in', () => {
  const DOC = '## Setup\n\n- one';

  it("'source' (the default) leaves Preview as styled source", () => {
    const view = mdView(DOC, { cursor: 'end' });
    expect(content(view)).toContain('## Setup');
    expect(view.dom.querySelector('.cm-md-item-mark')).toBeNull();
  });

  it('Mixed hides nothing even when typeset', () => {
    const view = mount(DOC, 'end', 'mixed');
    expect(content(view)).toContain('## Setup');
    expect(view.dom.querySelector('.cm-md-item-mark')).toBeNull();
  });

  it('switches live with the compartment', () => {
    const view = mdView(DOC, { cursor: 'end' });
    view.dispatch({ effects: markdownTypesetCompartment.reconfigure(markdownTypesetExtension('typeset')) });
    expect(markers(view)).toEqual(['- ']);
  });
});
