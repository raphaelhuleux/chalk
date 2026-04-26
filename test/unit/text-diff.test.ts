import { describe, it, expect } from 'vitest';
import { EditorState, EditorSelection, Transaction } from '@codemirror/state';
import { diffReplace } from '../../src/webview/utils/text-diff';

describe('diffReplace', () => {
  it('finds a middle insertion via prefix + suffix', () => {
    expect(diffReplace('hello world', 'hello big world')).toEqual({
      from: 6,
      to: 6,
      insert: 'big ',
    });
  });

  it('finds a deletion at the end', () => {
    expect(diffReplace('hello world', 'hello')).toEqual({
      from: 5,
      to: 11,
      insert: '',
    });
  });

  it('finds a deletion at the start', () => {
    expect(diffReplace('foobar', 'bar')).toEqual({
      from: 0,
      to: 3,
      insert: '',
    });
  });

  it('returns the whole-doc replace when no chars match', () => {
    expect(diffReplace('abc', 'xyz')).toEqual({
      from: 0,
      to: 3,
      insert: 'xyz',
    });
  });

  it('caps suffix scan so prefix and suffix do not overlap', () => {
    // both texts end in 'aa' but the second 'a' was already consumed
    // by the prefix scan — without a cap, suffix would walk into the
    // prefix and produce a negative-length insert.
    expect(diffReplace('aa', 'aaa')).toEqual({
      from: 2,
      to: 2,
      insert: 'a',
    });
  });

  it('handles empty new text', () => {
    expect(diffReplace('abc', '')).toEqual({ from: 0, to: 3, insert: '' });
  });

  it('handles empty old text', () => {
    expect(diffReplace('', 'abc')).toEqual({ from: 0, to: 0, insert: 'abc' });
  });
});

describe('diffReplace + CM6 selection mapping', () => {
  // The bug: a host→webview `update` previously dispatched
  // `from: 0, to: doc.length, insert: newText`. CM6 maps the selection
  // through that change with assoc=-1, collapsing any cursor inside the
  // replaced range to position 0 — the "cursor jumps to top of file"
  // symptom after autocomplete + an external doc edit.

  const oldText = 'line one\nline two\nline three';
  // Cursor on line three (well past the eventual edit on line one).
  const cursorPos = oldText.length - 2;
  const newText = 'LINE one\nline two\nline three';

  it('NAIVE full-doc replace collapses cursor to 0 (regression baseline)', () => {
    const state = EditorState.create({
      doc: oldText,
      selection: EditorSelection.cursor(cursorPos),
    });
    const tr = state.update({
      changes: { from: 0, to: oldText.length, insert: newText },
      annotations: [Transaction.addToHistory.of(false)],
    });
    expect(tr.state.selection.main.head).toBe(0);
  });

  it('minimal diff preserves cursor that sits in the unchanged suffix', () => {
    const state = EditorState.create({
      doc: oldText,
      selection: EditorSelection.cursor(cursorPos),
    });
    const r = diffReplace(oldText, newText);
    const tr = state.update({
      changes: { from: r.from, to: r.to, insert: r.insert },
      annotations: [Transaction.addToHistory.of(false)],
    });
    expect(tr.state.selection.main.head).toBe(cursorPos);
  });

  it('minimal diff preserves cursor in the prefix when the change is later in the doc', () => {
    const old2 = '\\begin{itemize}\n    \\item \n\\end{itemize}\n';
    // cursor right after the first \item
    const cursor2 = old2.indexOf('\\item ') + '\\item '.length;
    const state = EditorState.create({
      doc: old2,
      selection: EditorSelection.cursor(cursor2),
    });
    // simulate an external trailing-newline trim
    const new2 = old2.replace(/\n+$/, '\n');
    const r = diffReplace(old2, new2);
    const tr = state.update({
      changes: { from: r.from, to: r.to, insert: r.insert },
      annotations: [Transaction.addToHistory.of(false)],
    });
    expect(tr.state.selection.main.head).toBe(cursor2);
  });
});
