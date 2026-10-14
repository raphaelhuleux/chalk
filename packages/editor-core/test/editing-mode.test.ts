import { describe, it, expect, beforeEach } from 'vitest';
import { mockPort } from './helpers/views';
import { EditorState, Text } from '@codemirror/state';
import { mountEditor } from '../src/index';
import type { HostToEditorMessage } from '../src/index';
import { isSentenceEnd, sentenceRangeAt } from '../src/editor/typewriter-mode';
import { isPointerSelection } from '../src/editor/pointer-gesture';
import { sanitizeEditorConfig } from '../src/editor/theme';

const doc = (s: string) => Text.of(s.split('\n'));

/**
 * Editing modes (normal / zen / typewriter / focus) arrive via the
 * `editor-config` message's `editingMode` field. Typewriter centers the
 * caret line (cm-typewriter class + centering plugin); focus dims all but
 * the current sentence (cm-focus class + .cm-dim marks). They are
 * independent: typewriter must not dim, focus must not add the 48vh
 * centering padding. `zen` is accepted (native chrome-hiding) but yields
 * no editor extension.
 */
describe('sentence helpers', () => {
  it('finds the sentence around a mid-sentence position', () => {
    const d = doc('First one. Second two. Third three.');
    // caret inside "Second"
    expect(sentenceRangeAt(d, 14)).toEqual({ from: 11, to: 22 });
  });

  it('skips mid-token dots; a dot before whitespace ends the sentence', () => {
    expect(isSentenceEnd('e.g. apples', 1)).toBe(false); // "e.g" dot mid-token
    expect(isSentenceEnd('e.g. apples', 3)).toBe(true); // dot before space
    // Known heuristic limit: the trailing "e.g." dot splits the sentence.
    const d = doc('See e.g. the appendix. Next sentence.');
    expect(sentenceRangeAt(d, 10)).toEqual({ from: 9, to: 22 });
  });

  it('includes closing quotes and brackets in the sentence end', () => {
    const d = doc('He said "stop." Then left.');
    expect(sentenceRangeAt(d, 9)).toEqual({ from: 0, to: 15 });
  });

  it('collapses to an empty range on a blank line', () => {
    const d = doc('One.\n\nTwo.');
    const r = sentenceRangeAt(d, 5);
    expect(r.to <= r.from).toBe(true);
  });
});

describe('editing modes via editor-config', () => {
  let root: HTMLElement;

  beforeEach(() => {
    document.body.innerHTML = '';
    root = document.createElement('div');
    document.body.appendChild(root);
  });

  const editorEl = () => root.querySelector('.cm-editor');
  const setMode = (push: (m: HostToEditorMessage) => void, mode: string) =>
    push({ type: 'editor-config', config: { editingMode: mode } });

  // Caret sits at 0 after init: first sentence of line one is the focus keep
  // range; the whole first line is the typewriter keep range.
  const TEXT = 'First one. Second two.\nOther line.';

  it('typewriter dims other lines but keeps the whole current line', () => {
    const mock = mockPort();
    mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text: TEXT, language: 'md' });
    setMode(mock.push, 'typewriter');
    expect(editorEl()?.classList.contains('cm-typewriter')).toBe(true);
    expect(editorEl()?.classList.contains('cm-focus')).toBe(false);
    const dimmed = Array.from(root.querySelectorAll('.cm-dim'))
      .map((el) => el.textContent)
      .join('');
    expect(dimmed).toContain('Other line.');
    // Line-scoped, not sentence-scoped: the caret line's second sentence stays.
    expect(dimmed).not.toContain('Second two.');
    expect(dimmed).not.toContain('First one.');
  });

  it('focus adds cm-focus and dims everything but the current sentence', () => {
    const mock = mockPort();
    mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text: TEXT, language: 'md' });
    setMode(mock.push, 'focus');
    expect(editorEl()?.classList.contains('cm-focus')).toBe(true);
    expect(editorEl()?.classList.contains('cm-typewriter')).toBe(false);
    const dimmed = Array.from(root.querySelectorAll('.cm-dim'))
      .map((el) => el.textContent)
      .join('');
    // Sentence-scoped: even the caret line's other sentence dims.
    expect(dimmed).toContain('Second two.');
    expect(dimmed).toContain('Other line.');
    expect(dimmed).not.toContain('First one.');
  });

  it('normal and zen leave the editor unmarked', () => {
    for (const mode of ['normal', 'zen']) {
      document.body.innerHTML = '';
      root = document.createElement('div');
      document.body.appendChild(root);
      const mock = mockPort();
      mountEditor({ root, port: mock.port });
      mock.push({ type: 'init', text: TEXT, language: 'md' });
      setMode(mock.push, mode);
      expect(editorEl()?.classList.contains('cm-typewriter')).toBe(false);
      expect(editorEl()?.classList.contains('cm-focus')).toBe(false);
      expect(root.querySelectorAll('.cm-dim').length).toBe(0);
    }
  });

  it('switching typewriter -> focus -> normal leaves no stale mode', () => {
    const mock = mockPort();
    mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text: TEXT, language: 'md' });
    setMode(mock.push, 'typewriter');
    setMode(mock.push, 'focus');
    expect(editorEl()?.classList.contains('cm-typewriter')).toBe(false);
    expect(editorEl()?.classList.contains('cm-focus')).toBe(true);
    setMode(mock.push, 'normal');
    expect(editorEl()?.classList.contains('cm-focus')).toBe(false);
    expect(root.querySelectorAll('.cm-dim').length).toBe(0);
  });

  // The native reload path: DocumentController re-inits with editorConfig nil,
  // so a previously received mode must survive the rebuild.
  it('mode survives a subsequent init that carries no editorConfig', () => {
    const mock = mockPort();
    mountEditor({ root, port: mock.port });
    setMode(mock.push, 'focus'); // sent before the first init, must buffer
    mock.push({ type: 'init', text: TEXT, language: 'md' });
    expect(editorEl()?.classList.contains('cm-focus')).toBe(true);
    mock.push({ type: 'init', text: 'Reloaded. Text here.', language: 'md' });
    expect(editorEl()?.classList.contains('cm-focus')).toBe(true);
  });
});

/**
 * Typewriter centering must never run while a mouse gesture is live: CM6
 * re-resolves the drag head from SCREEN coordinates with no drag threshold, so
 * scrolling under a pressed button turns a click into a paragraph-wide
 * selection (owner report 2026-08-18). The gate is the `select.pointer` user
 * event, which CM6 puts on the mousedown caret placement and every drag
 * update; keyboard motion stays a plain `select` and centers immediately.
 * End-to-end coverage lives in Tests/browser/run.mjs — jsdom has no layout.
 */
describe('typewriter centering gate', () => {
  const state = EditorState.create({ doc: 'one two three' });
  const update = (userEvent: string) => ({
    transactions: [state.update({ selection: { anchor: 4 }, userEvent }) as never],
  });

  it('defers a mousedown-placed caret', () => {
    expect(isPointerSelection(update('select.pointer') as never)).toBe(true);
  });

  it('does not defer keyboard motion', () => {
    expect(isPointerSelection(update('select') as never)).toBe(false);
  });

  it('does not defer a typing-driven caret move', () => {
    expect(isPointerSelection(update('input.type') as never)).toBe(false);
  });
});

describe('editingMode sanitize', () => {
  it('falls back to normal on bogus or missing values', () => {
    expect(sanitizeEditorConfig({ editingMode: 'bogus' }).editingMode).toBe('normal');
    expect(sanitizeEditorConfig({}).editingMode).toBe('normal');
    expect(sanitizeEditorConfig({ editingMode: 'focus' }).editingMode).toBe('focus');
  });
});
