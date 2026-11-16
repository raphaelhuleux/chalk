import { describe, it, expect, beforeAll, beforeEach } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { EditorView } from '@codemirror/view';
import { EditorSelection } from '@codemirror/state';
import { undo } from '@codemirror/commands';
import { closeCompletion } from '@codemirror/autocomplete';
import { mountEditor } from '../src/index';
import { _testing } from '../src/editor/hsnips-plugin';
import { mockPort } from './helpers/views';

/**
 * Tab through snippet stops, typed key by key with the bundled snippets in a
 * mounted Markdown editor, so the whole Tab chain runs (hsnips, completion,
 * tabout, list indent, indentWithTab). `|` marks the caret, `[...]` a
 * selection.
 */
const BUNDLED = readFileSync(join(__dirname, '../assets/latex.hsnips'), 'utf8');

beforeAll(() => {
  Range.prototype.getClientRects = () => [] as unknown as DOMRectList;
  Range.prototype.getBoundingClientRect = () =>
    ({ x: 0, y: 0, width: 0, height: 0, top: 0, right: 0, bottom: 0, left: 0, toJSON: () => ({}) }) as DOMRect;
});

let root: HTMLElement;
beforeEach(() => {
  document.body.innerHTML = '';
  root = document.createElement('div');
  document.body.appendChild(root);
});

/** Mount `doc` (with a `|` caret) as Markdown with the bundled snippets. */
function mount(docWithCaret: string): EditorView {
  const pos = docWithCaret.indexOf('|');
  const text = docWithCaret.slice(0, pos) + docWithCaret.slice(pos + 1);
  const mock = mockPort();
  mountEditor({ root, port: mock.port });
  mock.push({ type: 'init', text, language: 'md' });
  mock.push({ type: 'hsnips', content: BUNDLED });
  const view = EditorView.findFromDOM(root)!;
  view.dispatch({ selection: EditorSelection.cursor(pos) });
  return view;
}

function type(view: EditorView, text: string): void {
  for (const ch of text) {
    const { from, to } = view.state.selection.main;
    view.dispatch({
      changes: { from, to, insert: ch },
      selection: EditorSelection.cursor(from + 1),
      userEvent: 'input.type',
    });
  }
}

function press(view: EditorView, key: string, shift = false): void {
  view.contentDOM.dispatchEvent(
    new KeyboardEvent('keydown', { key, shiftKey: shift, bubbles: true, cancelable: true }),
  );
}

const tab = (view: EditorView) => press(view, 'Tab');
const shiftTab = (view: EditorView) => press(view, 'Tab', true);

function show(view: EditorView): string {
  const { from, to } = view.state.selection.main;
  const doc = view.state.doc.toString();
  if (from === to) return doc.slice(0, from) + '|' + doc.slice(from);
  return doc.slice(0, from) + '[' + doc.slice(from, to) + ']' + doc.slice(to);
}

const inSession = (view: EditorView) => view.state.field(_testing.sessionField) !== null;

const DISPLAY = '$$\n|\n$$';

describe('one snippet', () => {
  it('Tab walks the stops, then leaves the math', () => {
    const v = mount(DISPLAY);
    type(v, '//a');
    tab(v);
    type(v, 'b');
    expect(show(v)).toBe('$$\n\\frac{a}{b|}\n$$');
    tab(v);
    expect(show(v)).toBe('$$\n\\frac{a}{b}|\n$$');
    expect(inSession(v)).toBe(false);
    tab(v);
    expect(show(v)).toBe('$$\n\\frac{a}{b}\n$$|');
  });

  it('Shift-Tab goes back to the previous stop with its text selected', () => {
    const v = mount(DISPLAY);
    type(v, '//a');
    tab(v);
    shiftTab(v);
    expect(show(v)).toBe('$$\n\\frac{[a]}{}\n$$');
  });

  it('a multi-line snippet: Tab reaches $0 after \\end', () => {
    const v = mount(DISPLAY);
    type(v, 'case');
    type(v, 'x');
    tab(v);
    expect(show(v)).toBe('$$\n\\begin{cases}\nx\n\\end{cases}|\n$$');
  });

  it('a snippet with only $0 inside a stop keeps the outer stops', () => {
    const v = mount(DISPLAY);
    type(v, '//asr');
    expect(show(v)).toBe('$$\n\\frac{a^{2}|}{}\n$$');
    tab(v);
    expect(show(v)).toBe('$$\n\\frac{a^{2}}{|}\n$$');
  });
});

describe('a snippet inside a stop', () => {
  it('after the inner snippet, Tab resumes the outer one', () => {
    const v = mount(DISPLAY);
    type(v, '//sqx');
    expect(show(v)).toBe('$$\n\\frac{\\sqrt{x|}}{}\n$$');
    tab(v);
    expect(show(v)).toBe('$$\n\\frac{\\sqrt{x}|}{}\n$$');
    tab(v);
    expect(show(v)).toBe('$$\n\\frac{\\sqrt{x}}{|}\n$$');
    type(v, 'y');
    tab(v);
    expect(show(v)).toBe('$$\n\\frac{\\sqrt{x}}{y}|\n$$');
  });

  it('two levels deep', () => {
    const v = mount(DISPLAY);
    type(v, '////a');
    tab(v);
    type(v, 'b');
    tab(v);
    expect(show(v)).toBe('$$\n\\frac{\\frac{a}{b}|}{}\n$$');
    tab(v);
    expect(show(v)).toBe('$$\n\\frac{\\frac{a}{b}}{|}\n$$');
  });

  it('in the outer second stop, Shift-Tab from the inner first stop goes to the outer first', () => {
    const v = mount(DISPLAY);
    type(v, '//a');
    tab(v);
    type(v, 'sq');
    expect(show(v)).toBe('$$\n\\frac{a}{\\sqrt{|}}\n$$');
    shiftTab(v);
    expect(show(v)).toBe('$$\n\\frac{[a]}{\\sqrt{}}\n$$');
  });

  it('inline math from prose (mk), then a fraction inside it', () => {
    const v = mount('Let |');
    type(v, 'mk');
    expect(show(v)).toBe('Let $|$');
    type(v, '//a');
    tab(v);
    type(v, 'b');
    tab(v);
    expect(show(v)).toBe('Let $\\frac{a}{b}|$');
    tab(v);
    expect(show(v)).toBe('Let $\\frac{a}{b}$|');
  });
});

describe('Escape', () => {
  it('ends the inner and the outer snippet', () => {
    const v = mount(DISPLAY);
    type(v, '//sqx');
    // Typing `x` asked for suggestions; an open popup takes the first Escape.
    closeCompletion(v);
    press(v, 'Escape');
    expect(inSession(v)).toBe(false);
  });
});

describe('edits that break the snippet end it', () => {
  it('undoing the expansion', () => {
    const v = mount(DISPLAY);
    type(v, '//');
    undo(v);
    expect(inSession(v)).toBe(false);
  });

  it('replacing the whole snippet', () => {
    const v = mount(DISPLAY);
    type(v, '//a');
    const line = v.state.doc.line(2);
    v.dispatch({ selection: { anchor: line.from, head: line.to } });
    type(v, 'z');
    expect(inSession(v)).toBe(false);
  });

  it('deleting the brace before the current stop', () => {
    const v = mount(DISPLAY);
    type(v, '//a');
    tab(v);
    // \frac{a}{|}: delete the `{` before the caret by hand.
    const head = v.state.selection.main.head;
    v.dispatch({ changes: { from: head - 1, to: head }, userEvent: 'delete.backward' });
    expect(inSession(v)).toBe(false);
  });

  it('typing between stops keeps the session', () => {
    const v = mount(DISPLAY);
    type(v, '//a');
    // The caret stays in $1; an edit elsewhere inside the snippet is fine.
    expect(inSession(v)).toBe(true);
  });

  it('moving the caret out of the snippet ends it', () => {
    const v = mount(DISPLAY);
    type(v, 'x + //a');
    v.dispatch({ selection: EditorSelection.cursor(v.state.doc.line(2).from + 1) });
    expect(inSession(v)).toBe(false);
  });
});

describe('mirrors', () => {
  it('beg: the environment name is mirrored, Tab moves to the body', () => {
    const v = mount(DISPLAY);
    type(v, 'beg');
    type(v, 'aligned');
    tab(v);
    expect(show(v)).toBe('$$\n\\begin{aligned}\n|\n\\end{aligned}\n$$');
  });
});

describe('time subscripts', () => {
  const cases: [string, string][] = [
    ['ct', 'c_t'],
    ['ct1', 'c_{t+1}'],
    ['ct2', 'c_{t+2}'],
    ['ctm', 'c_{t-1}'],
    ['Kt', 'K_t'],
    ['EE', '\\mathbb{E}'],
    ['EEt', '\\mathbb{E}_t'],
    ['EEt1', '\\mathbb{E}_{t+1}'],
    ['dt', 'dt'],
    ['xtilde', '\\tilde{x}'],
    ['xtrans', 'x^\\top'],
    ['2t', '2t'],
    [';vt', '\\vartheta'],
    ['ct+1', 'c_t+1'],
  ];
  it.each(cases)('%s → %s', (typed, out) => {
    const v = mount(DISPLAY);
    type(v, typed);
    expect(v.state.doc.line(2).text).toBe(out);
  });

  it('integral: `int` then t keeps dt', () => {
    const v = mount(DISPLAY);
    type(v, 'int');
    type(v, 'f');
    tab(v);
    type(v, 't');
    expect(v.state.doc.line(2).text).toBe('\\int f \\, dt');
  });
});
