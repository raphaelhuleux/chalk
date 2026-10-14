import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EditorSelection } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import type { Language } from '../src/editor/setup';
import { destroyViews, langView } from './helpers/views';

/**
 * Cmd+B / Cmd+I wrap the selection with per-language markers:
 * markdown uses `**`/`*`, LaTeX uses `\textbf{…}`/`\textit{…}`. Empty selection
 * inserts the markers around the caret; an already-wrapped selection toggles
 * back off. These are document edits, so jsdom exercises them layout-free.
 */
const mount = (doc: string, language: Language): EditorView => langView(doc, language);

// Destroy before the next rAF tick: an undestroyed view's measure cycle hits
// jsdom's missing layout APIs after the test ends.
afterEach(destroyViews);

// CodeMirror resolves `Mod` to Meta on macOS and Ctrl elsewhere. jsdom reports
// a non-mac platform, so the test drives `Mod` with Ctrl; production (Catalyst,
// mac) drives the same binding with Cmd.
function press(view: EditorView, key: string) {
  view.contentDOM.dispatchEvent(
    new KeyboardEvent('keydown', { key, ctrlKey: true, bubbles: true, cancelable: true }),
  );
}

describe('format-shortcuts: markdown', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  it('Cmd+B wraps the selection in **…** and keeps it selected', () => {
    const view = mount('hello world', 'md');
    view.dispatch({ selection: EditorSelection.range(6, 11) }); // "world"
    press(view, 'b');
    expect(view.state.doc.toString()).toBe('hello **world**');
    expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe('world');
  });

  it('Cmd+I wraps the selection in *…*', () => {
    const view = mount('hello world', 'md');
    view.dispatch({ selection: EditorSelection.range(0, 5) }); // "hello"
    press(view, 'i');
    expect(view.state.doc.toString()).toBe('*hello* world');
  });

  it('Cmd+B on an empty selection inserts **** and parks the caret between', () => {
    const view = mount('ab', 'md');
    view.dispatch({ selection: EditorSelection.cursor(1) });
    press(view, 'b');
    expect(view.state.doc.toString()).toBe('a****b');
    expect(view.state.selection.main.empty).toBe(true);
    expect(view.state.selection.main.head).toBe(3); // between the ** pairs
  });

  it('Cmd+B on an already-bold selection toggles it back off', () => {
    const view = mount('hello **world**', 'md');
    view.dispatch({ selection: EditorSelection.range(6, 15) }); // "**world**"
    press(view, 'b');
    expect(view.state.doc.toString()).toBe('hello world');
    expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe('world');
  });

  it('Cmd+B with the INNER text selected unwraps instead of nesting', () => {
    const view = mount('hello **world**', 'md');
    view.dispatch({ selection: EditorSelection.range(8, 13) }); // "world"
    press(view, 'b');
    expect(view.state.doc.toString()).toBe('hello world');
    expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe('world');
  });

  it('Cmd+B twice on an empty selection removes the fresh ** pair', () => {
    const view = mount('ab', 'md');
    view.dispatch({ selection: EditorSelection.cursor(1) });
    press(view, 'b'); // a****b, caret between
    press(view, 'b'); // toggles the empty pair back off
    expect(view.state.doc.toString()).toBe('ab');
    expect(view.state.selection.main.head).toBe(1);
  });

  it('Cmd+I on a selected **word** adds italic instead of peeling bold', () => {
    const view = mount('**word**', 'md');
    view.dispatch({ selection: EditorSelection.range(0, 8) });
    press(view, 'i');
    expect(view.state.doc.toString()).toBe('***word***');
  });

  it('Cmd+I with the text of **word** selected adds italic', () => {
    const view = mount('**word**', 'md');
    view.dispatch({ selection: EditorSelection.range(2, 6) });
    press(view, 'i');
    expect(view.state.doc.toString()).toBe('***word***');
    expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe('word');
  });

  it('Cmd+I with the caret in an empty **|** pair adds italic', () => {
    const view = mount('a****b', 'md');
    view.dispatch({ selection: EditorSelection.cursor(3) });
    press(view, 'i');
    expect(view.state.doc.toString()).toBe('a******b');
  });

  it('Cmd+I inside bold-italic removes only the italic (*** → **)', () => {
    const view = mount('***word***', 'md');
    view.dispatch({ selection: EditorSelection.range(3, 7) });
    press(view, 'i');
    expect(view.state.doc.toString()).toBe('**word**');
  });

  it('Cmd+B on *word* adds bold instead of nesting italic markers', () => {
    const view = mount('x *word* y', 'md');
    view.dispatch({ selection: EditorSelection.range(3, 7) });
    press(view, 'b');
    expect(view.state.doc.toString()).toBe('x ***word*** y');
  });

  it('Cmd+B inside bold-italic peels one layer (*** → *)', () => {
    const view = mount('***word***', 'md');
    view.dispatch({ selection: EditorSelection.range(3, 7) }); // "word"
    press(view, 'b');
    expect(view.state.doc.toString()).toBe('*word*');
  });
});

describe('format-shortcuts: latex', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  it('Cmd+B wraps the selection in \\textbf{…}', () => {
    const view = mount('hello world', 'tex');
    view.dispatch({ selection: EditorSelection.range(6, 11) });
    press(view, 'b');
    expect(view.state.doc.toString()).toBe('hello \\textbf{world}');
  });

  it('Cmd+I wraps the selection in \\textit{…}', () => {
    const view = mount('hello world', 'tex');
    view.dispatch({ selection: EditorSelection.range(6, 11) });
    press(view, 'i');
    expect(view.state.doc.toString()).toBe('hello \\textit{world}');
  });

  it('Cmd+B toggles an already-wrapped \\textbf{…} back off', () => {
    const view = mount('a \\textbf{b} c', 'tex');
    view.dispatch({ selection: EditorSelection.range(2, 12) }); // "\textbf{b}"
    press(view, 'b');
    expect(view.state.doc.toString()).toBe('a b c');
  });

  it('Cmd+B with the argument selected unwraps instead of nesting', () => {
    const view = mount('a \\textbf{b} c', 'tex');
    view.dispatch({ selection: EditorSelection.range(10, 11) }); // "b"
    press(view, 'b');
    expect(view.state.doc.toString()).toBe('a b c');
    expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe('b');
  });
});
