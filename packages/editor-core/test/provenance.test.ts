import { describe, expect, it } from 'vitest';
import { undo, redo } from '@codemirror/commands';
import { EditorSelection, Transaction } from '@codemirror/state';
import { type EditorView, runScopeHandlers } from '@codemirror/view';
import {
  acceptAiMarks,
  aiWriteEffect,
  getAiMarks,
  rejectAiMarks,
  restoreAiMarks,
} from '../src/editor/provenance';
import { wordHunks } from '../src/utils/word-diff';
import { mdView } from './helpers/views';

/** Mod-b through the real keymap. jsdom's platform isn't Mac, so Mod is Ctrl. */
const wrapBold = (view: EditorView): boolean =>
  runScopeHandlers(view, new KeyboardEvent('keydown', { key: 'b', ctrlKey: true }), 'editor');

/** What mount.ts does for an `update` with `origin: 'external'`. */
function write(view: EditorView, text: string): void {
  const old = view.state.doc.toString();
  const hunks = wordHunks(old, text);
  view.dispatch({
    changes: hunks.map((h) => ({ from: h.fromA, to: h.toA, insert: text.slice(h.fromB, h.toB) })),
    effects: aiWriteEffect.of(hunks),
    annotations: [Transaction.addToHistory.of(false), Transaction.remote.of(true)],
  });
}

const marked = (view: EditorView): string[] =>
  getAiMarks(view.state).map((m) => view.state.sliceDoc(m.from, m.to));
const removed = (view: EditorView): string[] => getAiMarks(view.state).map((m) => m.deleted);
const typeAt = (view: EditorView, at: number, insert: string): void =>
  view.dispatch({ changes: { from: at, insert }, userEvent: 'input.type' });

describe('AI marks', () => {
  it('marks only what an outside write changed, hunk by hunk', () => {
    const view = mdView('alpha\n\nbeta\n\ngamma\n');
    write(view, 'alpha\n\nnew beta\n\ngamma rays\n');
    expect(marked(view)).toEqual(['new ', ' rays']);
    expect(removed(view)).toEqual(['', '']);
  });

  it('adds no mark for a plain edit', () => {
    const view = mdView('alpha');
    typeAt(view, 5, ' beta');
    expect(getAiMarks(view.state)).toEqual([]);
  });

  it('records the text a write replaced, and a pure deletion', () => {
    const view = mdView('one fixed two\n\ngone line\n\nend\n');
    write(view, 'one fast two\n\nend\n');
    expect(marked(view)).toEqual(['fast', '']);
    expect(removed(view)).toEqual(['fixed', '\n\ngone line']);
  });

  it('splits a mark when you type inside it', () => {
    const view = mdView('');
    write(view, 'hello world');
    typeAt(view, 5, ' big');
    expect(view.state.doc.toString()).toBe('hello big world');
    expect(marked(view)).toEqual(['hello', ' world']);
  });

  it('leaves text typed at either edge unmarked', () => {
    const view = mdView('a\n');
    write(view, 'a\nai text\n');
    const mark = getAiMarks(view.state)[0];
    typeAt(view, mark.to, 'X');
    typeAt(view, mark.from, 'Y');
    expect(view.state.doc.toString()).toBe('a\nYai text\nX');
    expect(marked(view)).toEqual(['ai text\n']);
  });

  it('keeps the deleted text on the first piece of a split', () => {
    const view = mdView('one fixed two');
    write(view, 'one quite fast two');
    const mark = getAiMarks(view.state)[0];
    typeAt(view, mark.from + 5, 'human ');
    expect(removed(view)[0]).toContain('fixed');
    expect(removed(view)[1]).toBe('');
  });

  it('leaves no deletion marker when AI text replaces AI text', () => {
    const view = mdView('intro\n');
    write(view, 'intro\nfirst draft\n');
    write(view, 'intro\nsecond draft\n');
    expect(removed(view).join('')).toBe('');
    expect(marked(view).join('')).toContain('second');
  });

  it('keeps the original when the AI rewrites its own replacement', () => {
    const view = mdView('one fixed two');
    write(view, 'one fast two');
    write(view, 'one rapid two');
    expect(marked(view)).toEqual(['rapid']);
    expect(removed(view)).toEqual(['fixed']);
    rejectAiMarks(view);
    expect(view.state.doc.toString()).toBe('one fixed two');
  });

  it('drops an AI insertion the AI itself removes', () => {
    const view = mdView('keep\n');
    write(view, 'keep\nextra\n');
    write(view, 'keep\n');
    expect(getAiMarks(view.state)).toEqual([]);
  });

  it('accept clears marks and keeps the text, and undoes', () => {
    const view = mdView('one fixed two');
    write(view, 'one fast two');
    acceptAiMarks(view);
    expect(getAiMarks(view.state)).toEqual([]);
    expect(view.state.doc.toString()).toBe('one fast two');
    undo(view);
    expect(marked(view)).toEqual(['fast']);
    redo(view);
    expect(getAiMarks(view.state)).toEqual([]);
  });

  it('reject restores deleted text, and undoes with its mark', () => {
    const view = mdView('one fixed two\n\ngone\n\nend\n');
    write(view, 'one fast two\n\nend\n');
    rejectAiMarks(view);
    expect(view.state.doc.toString()).toBe('one fixed two\n\ngone\n\nend\n');
    expect(getAiMarks(view.state)).toEqual([]);
    undo(view);
    expect(view.state.doc.toString()).toBe('one fast two\n\nend\n');
    expect(removed(view)).toEqual(['fixed', '\n\ngone']);
  });

  it('acts only on marks the selection touches', () => {
    const view = mdView('aa\n\nbb\n');
    write(view, 'aa one\n\nbb two\n');
    view.dispatch({ selection: EditorSelection.single(1, 5) });
    acceptAiMarks(view);
    expect(marked(view)).toEqual([' two']);
    view.dispatch({ selection: EditorSelection.cursor(0) });
    rejectAiMarks(view);
    expect(view.state.doc.toString()).toBe('aa one\n\nbb\n');
  });

  it('keeps the mark when the selection is wrapped in markup', () => {
    const view = mdView('aa\n');
    write(view, 'aa\nai text\n');
    const mark = getAiMarks(view.state)[0];
    view.dispatch({ selection: EditorSelection.single(mark.from, mark.to - 1) });
    wrapBold(view);
    expect(view.state.doc.toString()).toBe('aa\n**ai text**\n');
    expect(marked(view).join('')).toContain('ai text');
  });

  it('restores host marks, dropping ranges that do not fit', () => {
    const view = mdView('short');
    restoreAiMarks(view, [
      { from: 1, to: 3, deleted: '' },
      { from: 3, to: 99, deleted: '' },
      { from: 4, to: 4, deleted: '' },
    ]);
    expect(getAiMarks(view.state)).toEqual([{ from: 1, to: 3, deleted: '' }]);
    undo(view);
    expect(getAiMarks(view.state)).toHaveLength(1);
  });
});
