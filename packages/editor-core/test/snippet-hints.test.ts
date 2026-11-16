import { describe, it, expect, beforeAll, afterEach } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { EditorSelection } from '@codemirror/state';
import { EditorView, runScopeHandlers } from '@codemirror/view';
import { parseHSnips } from '../src/editor/hsnips-parser';
import { setSnippets, _testing as hsnipsTesting } from '../src/editor/hsnips-plugin';
import { _testing, snippetHintCommands, staticPreview } from '../src/editor/snippet-hints';
import { defaultEditorConfig } from '../src/editor/theme';
import { mountEditor } from '../src/index';
import { destroyViews, mdView, mockPort, texView } from './helpers/views';

const SOURCE = readFileSync(join(__dirname, '../assets/latex.hsnips'), 'utf8');
const snippets = parseHSnips(SOURCE);
const on = { config: { ...defaultEditorConfig, snippetHints: 'on' as const } };

beforeAll(() => {
  Range.prototype.getClientRects = () => [] as unknown as DOMRectList;
  Range.prototype.getBoundingClientRect = () =>
    ({ x: 0, y: 0, width: 0, height: 0, top: 0, right: 0, bottom: 0, left: 0, toJSON: () => ({}) }) as DOMRect;
});
afterEach(destroyViews);

function typeOne(view: EditorView, ch: string): void {
  const pos = view.state.selection.main.head;
  view.dispatch({
    changes: { from: pos, to: pos, insert: ch },
    selection: EditorSelection.cursor(pos + 1),
    userEvent: 'input.type',
  });
}

function key(view: EditorView, name: string): boolean {
  const keyCode = { Tab: 9, Escape: 27, ArrowUp: 38, ArrowDown: 40 }[name];
  return runScopeHandlers(view, new KeyboardEvent('keydown', { key: name, keyCode }), 'editor');
}

/** A tex editor in inline math with `keys` typed after `$`. */
function inMath(keys: string, opts = on): EditorView {
  const view = texView('$$', { cursor: 1, ...opts });
  view.dispatch({ effects: setSnippets.of(snippets) });
  for (const ch of keys) typeOne(view, ch);
  return view;
}

const triggers = (view: EditorView) =>
  view.state.field(_testing.hintField).hints.map((h) => h.snippet.trigger);

const caret = (view: EditorView) => {
  const doc = view.state.doc.toString();
  const head = view.state.selection.main.head;
  return doc.slice(0, head) + '|' + doc.slice(head);
};

describe('what opens hints', () => {
  it('a leader: `/` offers the fraction first', () => {
    expect(triggers(inMath('/'))[0]).toBe('//');
  });

  it('`;` offers Greek letters, capped at eight', () => {
    const t = triggers(inMath(';'));
    expect(t).toHaveLength(8);
    expect(t.every((x) => x.startsWith(';'))).toBe(true);
    expect(t[0]).toBe(';a');
  });

  it('a longer prefix narrows: `;t` gives `;th` and `;ta`', () => {
    expect(triggers(inMath(';t'))).toEqual([';th', ';ta']);
  });

  it('a hand-typed `\\fr` offers `//`', () => {
    const view = inMath('\\fr');
    const hints = view.state.field(_testing.hintField).hints;
    expect(hints[0].kind).toBe('name');
    expect(hints[0].snippet.trigger).toBe('//');
  });

  it('two letters at a word start: `su` offers `sum`', () => {
    expect(triggers(inMath('su'))).toContain('sum');
  });

  it.each([
    ['a lone letter', 'x'],
    ['a subscript', 'x_t'],
    ['the subscript in `x_{t+1`', 'x_{t+1'],
    ['an operator', 'a='],
    ['a decimal point', '0.'],
    ['letters inside a word', 'xsu'],
  ])('%s opens nothing', (_name, keys) => {
    expect(triggers(inMath(keys))).toEqual([]);
  });

  it('nothing outside math or inside \\text{}', () => {
    const prose = texView('', { cursor: 0, ...on });
    prose.dispatch({ effects: setSnippets.of(snippets) });
    typeOne(prose, ';');
    expect(triggers(prose)).toEqual([]);
    const text = texView('$\\text{}$', { cursor: 7, ...on });
    text.dispatch({ effects: setSnippets.of(snippets) });
    typeOne(text, ';');
    expect(triggers(text)).toEqual([]);
  });

  it('never lists a regex snippet', () => {
    for (const keys of [';', '/', 'su', '\\fr', '\\ma', '..', 'lr']) {
      const view = inMath(keys);
      for (const h of view.state.field(_testing.hintField).hints) {
        expect(h.snippet.regexp).toBeUndefined();
      }
      view.destroy();
    }
  });

  it('is off by default: no list, no tooltip', () => {
    const view = inMath('/', {} as typeof on);
    expect(triggers(view)).toEqual([]);
    expect(view.dom.querySelector('.cm-snippet-hints')).toBeNull();
  });

  it('renders a row per hint with the trigger', () => {
    const view = inMath('/');
    const rows = view.dom.querySelectorAll('.cm-snippet-hints li');
    expect(rows.length).toBeGreaterThan(0);
    expect(rows[0].getAttribute('aria-selected')).toBe('true');
    expect(rows[0].querySelector('.cm-snippet-hint-trigger')?.textContent).toBe('//');
  });
});

describe('keys', () => {
  it('Tab inserts the hint over the typed prefix and starts its session', () => {
    const view = inMath('/');
    expect(key(view, 'Tab')).toBe(true);
    expect(caret(view)).toBe('$\\frac{|}{}$');
    expect(view.state.field(hsnipsTesting.sessionField)).not.toBeNull();
    expect(triggers(view)).toEqual([]);
  });

  it('Tab on a name hint replaces the typed name', () => {
    const view = inMath('\\fr');
    key(view, 'Tab');
    expect(caret(view)).toBe('$\\frac{|}{}$');
  });

  it('Down then Tab inserts the second hint', () => {
    const view = inMath(';');
    key(view, 'ArrowDown');
    expect(view.state.field(_testing.hintField).selected).toBe(1);
    key(view, 'Tab');
    expect(view.state.doc.toString()).toBe('$\\beta$');
  });

  it('Up wraps to the last hint', () => {
    const view = inMath(';t');
    key(view, 'ArrowUp');
    key(view, 'Tab');
    expect(view.state.doc.toString()).toBe('$\\tau$');
  });

  it('Escape hides the list; the next key reopens it', () => {
    const view = inMath(';');
    expect(key(view, 'Escape')).toBe(true);
    expect(triggers(view)).toEqual([]);
    typeOne(view, 't');
    expect(triggers(view)).toEqual([';th', ';ta']);
  });

  it('a caret move clears the list', () => {
    const view = inMath(';');
    view.dispatch({ selection: EditorSelection.cursor(1) });
    expect(triggers(view)).toEqual([]);
  });

  it('arrows pass through with a single hint', () => {
    const view = inMath('\\alph');
    expect(view.state.field(_testing.hintField).hints).toHaveLength(1);
    expect(snippetHintCommands.down(view)).toBe(false);
  });

  it('a `\\name` typed in full lets Tab through to tabout', () => {
    const view = texView('$x_{}$', { cursor: 4, ...on });
    view.dispatch({ effects: setSnippets.of(snippets) });
    for (const ch of '\\alpha') typeOne(view, ch);
    expect(triggers(view)).toContain(';a');
    key(view, 'Tab');
    expect(caret(view)).toBe('$x_{\\alpha}|$');
  });

  it('with no hint, Tab is still tabout', () => {
    const view = inMath('x_{t+1');
    view.dispatch({ changes: { from: view.state.selection.main.head, insert: '}' } });
    key(view, 'Tab');
    expect(caret(view)).toBe('$x_{t+1}|$');
  });

  it('hints on: Tab in `dm` still walks } then ] then out', () => {
    const view = mdView('', { cursor: 0, ...on });
    view.dispatch({ effects: setSnippets.of(snippets) });
    for (const ch of 'dm[]') typeOne(view, ch);
    view.dispatch({ selection: EditorSelection.cursor(view.state.selection.main.head - 1) });
    for (const ch of 'x__t+1') typeOne(view, ch);
    key(view, 'Tab');
    expect(caret(view)).toBe('$$\n[x_{t+1}|]\n$$');
    key(view, 'Tab');
    expect(caret(view)).toBe('$$\n[x_{t+1}]|\n$$');
    key(view, 'Tab');
    expect(caret(view)).toBe('$$\n[x_{t+1}]\n$$|');
  });

  it('inside a `dm` session the list still wins Tab', () => {
    const view = mdView('', { cursor: 0, ...on });
    view.dispatch({ effects: setSnippets.of(snippets) });
    for (const ch of 'dm/') typeOne(view, ch);
    key(view, 'Tab');
    expect(caret(view)).toBe('$$\n\\frac{|}{}\n$$');
  });
});

describe('setting', () => {
  it('editor-config turns it on and off live', () => {
    document.body.innerHTML = '';
    const root = document.createElement('div');
    document.body.appendChild(root);
    const mock = mockPort();
    const handle = mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text: '$$', language: 'tex' });
    mock.push({ type: 'hsnips', content: SOURCE });
    const view = EditorView.findFromDOM(root)!;
    view.dispatch({ selection: EditorSelection.cursor(1) });
    typeOne(view, ';');
    expect(triggers(view)).toEqual([]);
    mock.push({ type: 'editor-config', config: { snippetHints: 'on' } });
    typeOne(view, 't');
    expect(triggers(view)).toEqual([';th', ';ta']);
    mock.push({ type: 'editor-config', config: { snippetHints: 'off' } });
    expect(triggers(view)).toEqual([]);
    handle?.destroy?.();
  });
});

describe('staticPreview', () => {
  it('boxes empty stops and keeps defaults', () => {
    expect(staticPreview('\\frac{$1}{$2}$0')).toBe('\\frac{\\square}{\\square}');
    expect(staticPreview('\\sqrt{${1:x}}')).toBe('\\sqrt{x}');
    expect(staticPreview('\\alpha')).toBe('\\alpha');
  });
});
