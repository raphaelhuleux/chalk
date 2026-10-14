import { describe, it, expect, beforeEach, beforeAll } from 'vitest';
import { mockPort } from './helpers/views';
import { EditorView } from '@codemirror/view';
import { EditorSelection } from '@codemirror/state';
import { mountEditor } from '../src/index';

const SNIPPETS = `
snippet ;; "Inline math" iA
\\$$0\\$
endsnippet

snippet frr "fraction" i
\\frac{$1}{$2}$0
endsnippet

context math(context)
snippet mo "math only manual"
\\mu
endsnippet
`;

function pressTab(view: EditorView) {
  view.contentDOM.dispatchEvent(
    new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true }),
  );
}

beforeAll(() => {
  if (typeof Range.prototype.getClientRects !== 'function') {
    Range.prototype.getClientRects = () => [] as unknown as DOMRectList;
  }
  if (typeof Range.prototype.getBoundingClientRect !== 'function') {
    Range.prototype.getBoundingClientRect = () =>
      ({ x: 0, y: 0, width: 0, height: 0, top: 0, right: 0, bottom: 0, left: 0, toJSON: () => ({}) }) as DOMRect;
  }
});

/**
 * Manual Tab expansion through the REAL mounted keymap chain
 * (hsnips → autocomplete → tabout → indent), not a direct call into the
 * plugin. Guards the precedence contract in tabout.ts: hsnips' Tab handler
 * must get first crack, expand a matching non-automatic snippet, and fall
 * through cleanly (to tabout) when nothing matches.
 */
describe('manual Tab expansion in a mounted editor', () => {
  let root: HTMLElement;

  beforeEach(() => {
    document.body.innerHTML = '';
    root = document.createElement('div');
    document.body.appendChild(root);
  });

  function mountWith(text: string, cursor: number): EditorView {
    const mock = mockPort();
    mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text, language: 'tex' });
    mock.push({ type: 'hsnips', content: SNIPPETS });
    const view = EditorView.findFromDOM(root)!;
    view.dispatch({ selection: EditorSelection.cursor(cursor) });
    return view;
  }

  it('expands a flagless snippet on Tab, ahead of tabout', () => {
    // `$k frr|$` — cursor inside math right after the trigger. Tabout would
    // jump past the `$`; hsnips must win and expand instead.
    const view = mountWith('$k frr$', 6);
    pressTab(view);
    expect(view.state.doc.toString()).toBe('$k \\frac{}{}$');
  });

  it('honors math(context) on the manual path (facet-provided context)', () => {
    const view = mountWith('$k mo$', 5);
    pressTab(view);
    expect(view.state.doc.toString()).toBe('$k \\mu$');
  });

  it('falls through to tabout when nothing matches at the cursor', () => {
    const view = mountWith('$k zz$', 5);
    pressTab(view);
    // No expansion; tabout exits the math scope (cursor past the closing $).
    expect(view.state.doc.toString()).toBe('$k zz$');
    expect(view.state.selection.main.head).toBe(6);
  });

  it('mathOnly manual snippet is inert outside math', () => {
    const view = mountWith('k mo', 4);
    pressTab(view);
    expect(view.state.doc.toString()).not.toContain('\\mu');
  });

  it('a $0-only snippet ends immediately: next Tab reaches manual expansion', () => {
    // `;;` expands to `$|$` with only a $0 stop — no session may linger,
    // or this Tab would be eaten by a no-op session exit instead of
    // expanding `frr` (the bug found driving the real browser bundle).
    const view = mountWith('', 0);
    view.dispatch(view.state.replaceSelection(';'), { userEvent: 'input.type' });
    view.dispatch(view.state.replaceSelection(';'), { userEvent: 'input.type' });
    expect(view.state.doc.toString()).toBe('$$');
    for (const ch of 'k frr') {
      view.dispatch(view.state.replaceSelection(ch), { userEvent: 'input.type' });
    }
    pressTab(view);
    expect(view.state.doc.toString()).toBe('$k \\frac{}{}$');
  });
});
