import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { mockPort } from './helpers/views';
import { EditorView } from '@codemirror/view';
import { mountEditor } from '../src/index';
import type { MountedEditor } from '../src/index';

// tex, not md: the tex extractor is a line scan and needs no syntax tree,
// so the snapshot is deterministic in jsdom without a parse settle.
const DOC = ['\\section{A}', 'text', '\\section{B}', 'more'].join('\n');

describe('outline subscription', () => {
  let root: HTMLElement;
  // Every editor mounted by a test, torn down in afterEach. A leaked,
  // undestroyed CM6 view from a previous test stays attached to jsdom's one
  // shared `document` — its DOMObserver's periodic DOM-selection read-back
  // (CodeMirror's own resync path, `applyDOMChange` in @codemirror/view)
  // fires against the *next* test's view and can dispatch a spurious
  // corrective `userEvent: "select"` transaction, moving that view's
  // selection out from under it. Real hosts never see this: each editor
  // lives in its own page (WKWebView / webview) and is destroyed on
  // teardown, so there is only ever one view per document. Destroying here
  // keeps the suite honest about that guarantee instead of laundering the
  // leak through a less caret-sensitive assertion.
  let editors: MountedEditor[] = [];

  beforeEach(() => {
    vi.useFakeTimers();
    document.body.innerHTML = '';
    root = document.createElement('div');
    document.body.appendChild(root);
    editors = [];
  });

  afterEach(() => {
    for (const editor of editors) editor.destroy();
    editors = [];
    vi.useRealTimers();
  });

  function mounted(onOutline: ReturnType<typeof vi.fn>) {
    const mock = mockPort();
    const editor = mountEditor({
      root,
      port: mock.port,
      onOutline: onOutline as ((snapshot: { items: any[]; cursorLine: number }) => void) | undefined,
    });
    editors.push(editor);
    mock.push({ type: 'init', text: DOC, language: 'tex' });
    const view = EditorView.findFromDOM(root);
    if (!view) throw new Error('no EditorView mounted');
    return { editor, view, mock };
  }

  it('pushes nothing while unsubscribed', () => {
    const onOutline = vi.fn();
    const { view } = mounted(onOutline);
    view.dispatch({ changes: { from: view.state.doc.length, insert: '\n\\section{C}' } });
    vi.advanceTimersByTime(1000);
    expect(onOutline).not.toHaveBeenCalled();
  });

  it('installs no update listener while unsubscribed, and exactly one after resubscribing', () => {
    const onOutline = vi.fn();
    const { editor, view } = mounted(onOutline);
    editor.setOutlineSubscription(true);
    editor.setOutlineSubscription(false);
    view.dispatch({ changes: { from: 0, insert: 'x' } });
    vi.advanceTimersByTime(120);
    expect(onOutline).not.toHaveBeenCalled();
    // Resubscribing schedules its own snapshot; the edit that follows lands
    // inside the same debounce window and coalesces with it, so the count
    // still reads one listener, not two.
    editor.setOutlineSubscription(true);
    view.dispatch({ changes: { from: 0, insert: 'y' } });
    vi.advanceTimersByTime(120);
    expect(onOutline).toHaveBeenCalledTimes(1);
  });

  it('subscribing after init pushes the current document once, with no edit', () => {
    const onOutline = vi.fn();
    const { editor } = mounted(onOutline);
    editor.setOutlineSubscription(true);
    vi.advanceTimersByTime(119);
    expect(onOutline).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1);
    expect(onOutline).toHaveBeenCalledTimes(1);
    expect(onOutline.mock.calls[0][0].items.map((i: { title: string }) => i.title)).toEqual([
      'A',
      'B',
    ]);
    // And only once: the subscribe-time push must not arm a repeat.
    vi.advanceTimersByTime(1000);
    expect(onOutline).toHaveBeenCalledTimes(1);
  });

  it('pushes one debounced snapshot after a burst of document changes', () => {
    const onOutline = vi.fn();
    const { editor, view } = mounted(onOutline);
    editor.setOutlineSubscription(true);
    view.dispatch({ changes: { from: view.state.doc.length, insert: '\n\\section{C' } });
    view.dispatch({ changes: { from: view.state.doc.length, insert: '}' } });
    vi.advanceTimersByTime(119);
    expect(onOutline).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1);
    expect(onOutline).toHaveBeenCalledTimes(1);
    const snapshot = onOutline.mock.calls[0][0];
    expect(snapshot.items.map((i: { title: string }) => i.title)).toEqual(['A', 'B', 'C']);
  });

  it('a selection-only change pushes the new cursor line', () => {
    const onOutline = vi.fn();
    const { editor, view } = mounted(onOutline);
    editor.setOutlineSubscription(true);
    // Line 3 is a LaTeX heading (`\section{B}`), a concealed construct — the
    // regression-relevant case for the outline's own main use case (jumping
    // between headings). See the afterEach comment above: without per-test
    // teardown, a leaked prior view's DOMObserver read-back corrupts this.
    view.dispatch({ selection: { anchor: view.state.doc.line(3).from } });
    vi.advanceTimersByTime(120);
    expect(onOutline).toHaveBeenCalledTimes(1);
    expect(onOutline.mock.calls[0][0].cursorLine).toBe(3);
  });

  it('unsubscribing cancels a pending push and stops later ones', () => {
    const onOutline = vi.fn();
    const { editor, view } = mounted(onOutline);
    editor.setOutlineSubscription(true);
    view.dispatch({ changes: { from: 0, insert: 'x' } });
    vi.advanceTimersByTime(60);
    editor.setOutlineSubscription(false);
    vi.advanceTimersByTime(200);
    view.dispatch({ changes: { from: 0, insert: 'y' } });
    vi.advanceTimersByTime(200);
    expect(onOutline).not.toHaveBeenCalled();
  });

  it('a re-init while subscribed pushes the new document once', () => {
    const onOutline = vi.fn();
    const { editor, mock } = mounted(onOutline);
    editor.setOutlineSubscription(true);
    mock.push({ type: 'init', text: '\\section{Z}', language: 'tex' });
    vi.advanceTimersByTime(120);
    expect(onOutline).toHaveBeenCalledTimes(1);
    expect(onOutline.mock.calls[0][0].items.map((i: { title: string }) => i.title)).toEqual(['Z']);
  });

  it('subscribing before init takes effect once the view exists', () => {
    const mock = mockPort();
    const onOutline = vi.fn();
    const editor = mountEditor({ root, port: mock.port, onOutline });
    editors.push(editor);
    editor.setOutlineSubscription(true);
    mock.push({ type: 'init', text: DOC, language: 'tex' });
    vi.advanceTimersByTime(120);
    expect(onOutline).toHaveBeenCalledTimes(1);
  });

  it('destroy clears a pending push', () => {
    const onOutline = vi.fn();
    const { editor, view } = mounted(onOutline);
    editor.setOutlineSubscription(true);
    view.dispatch({ changes: { from: 0, insert: 'x' } });
    editor.destroy();
    vi.advanceTimersByTime(200);
    expect(onOutline).not.toHaveBeenCalled();
  });
});
