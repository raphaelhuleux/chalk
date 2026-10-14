import { describe, it, expect, beforeEach, vi } from 'vitest';
import { mockPort } from './helpers/views';
import { EditorView } from '@codemirror/view';
import { mountEditor } from '../src/index';
import type { HostToEditorMessage } from '../src/index';
import { openExternal } from '../src/host-port';
import { defaultEditorConfig } from '../src/editor/theme';
import { _testing as hsnipsTesting } from '../src/editor/hsnips-plugin';

/**
 * Exercises the host seam: mountEditor must speak the 9-message protocol over
 * an injected HostPort, with no knowledge of VS Code or Tauri. A mock port
 * captures outbound messages and lets the test push inbound ones.
 */
describe('mountEditor host seam', () => {
  let root: HTMLElement;

  beforeEach(() => {
    document.body.innerHTML = '';
    root = document.createElement('div');
    document.body.appendChild(root);
  });

  it('sends ready on mount and registers an inbound handler', () => {
    const mock = mockPort();
    mountEditor({ root, port: mock.port });
    expect(mock.sent).toEqual([{ type: 'ready' }]);
    expect(mock.hasHandler).toBe(true);
  });

  it('renders the document text on init', () => {
    const mock = mockPort();
    mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text: 'hello world', language: 'tex' });
    const content = root.querySelector('.cm-content');
    expect(content).not.toBeNull();
    expect(content?.textContent ?? '').toContain('hello world');
  });

  it('applies an external update to the rendered document', () => {
    const mock = mockPort();
    mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text: 'first', language: 'md' });
    mock.push({ type: 'update', text: 'second' });
    const content = root.querySelector('.cm-content');
    expect(content?.textContent ?? '').toContain('second');
  });

  // Remote updates must carry a scroll-snapshot effect: a big rewrite resets
  // measured line heights to (undershooting) estimates, and without the
  // anchor the clamped scrollTop strands the viewport in the past-end spacer
  // — a blank pane below the last line. jsdom can't measure the geometry
  // (the Playwright harness covers that), so this locks the dispatch shape.
  it('dispatches host updates with a viewport anchor effect', () => {
    const mock = mockPort();
    mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text: 'line1\nline2\nline3', language: 'md' });

    const view = EditorView.findFromDOM(root);
    if (!view) throw new Error('no EditorView mounted');
    const specs: unknown[] = [];
    const realDispatch = view.dispatch.bind(view);
    view.dispatch = ((...args: unknown[]) => {
      specs.push(args[0]);
      return (realDispatch as (...a: unknown[]) => void)(...args);
    }) as typeof view.dispatch;

    mock.push({ type: 'update', text: 'line1\nCHANGED\nline3' });

    expect(specs).toHaveLength(1);
    const spec = specs[0] as { effects?: unknown };
    expect(spec.effects).toBeTruthy();
  });

  // A bare `update` before the first `init` has no view to render into and no
  // language to build one — it must be ignored without throwing, and the
  // following `init` is authoritative (its text wins). The native host
  // guarantees this ordering (DocumentController.pushText sends `init` first),
  // so the pre-view `update` is always the older message.
  it('ignores an update before init without throwing; init text wins', () => {
    const mock = mockPort();
    mountEditor({ root, port: mock.port });

    expect(() => mock.push({ type: 'update', text: 'pre-view text' })).not.toThrow();
    expect(root.querySelector('.cm-content')).toBeNull();

    mock.push({ type: 'init', text: 'authoritative init text', language: 'md' });
    const content = root.querySelector('.cm-content');
    expect(content?.textContent ?? '').toContain('authoritative init text');
    expect(content?.textContent ?? '').not.toContain('pre-view text');
  });

  // The native host reuses one editor surface across tabs and switches
  // languages by sending a fresh `init` (see DocumentController.reopen). This
  // locks the contract that mechanism relies on: a second `init` with a
  // different language rebuilds the view in the new mode. Regression guard for
  // the bug where a .tex file browsed into a .md tab kept markdown mode (no
  // LaTeX highlighting, \[…\]/\(…\) not rendered).
  it('rebuilds into tex mode when re-initialized with a different language', () => {
    const mock = mockPort();
    mountEditor({ root, port: mock.port });
    const src = '\\section{Title}\n\\[a\\]';

    // Markdown mode: \section is plain text and \[…\] is not math.
    mock.push({ type: 'init', text: src, language: 'md' });
    expect(root.querySelector('.cm-h1')).toBeNull();
    expect(root.querySelector('.cm-tex-math-display')).toBeNull();

    // Re-init as tex: sectioning gets heading styling and \[…\] renders.
    mock.push({ type: 'init', text: src, language: 'tex' });
    expect(root.querySelector('.cm-h1')?.textContent).toContain('Title');
    expect(root.querySelector('.cm-tex-math-display')).not.toBeNull();
  });

  it('drops malformed inbound messages without throwing', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const mock = mockPort();
    mountEditor({ root, port: mock.port });
    expect(() =>
      mock.push({ type: 'nonsense' } as unknown as HostToEditorMessage),
    ).not.toThrow();
    expect(warn).toHaveBeenCalled();
    warn.mockRestore();
  });

  it('tears down the view and unsubscribes on destroy', () => {
    const mock = mockPort();
    const handle = mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text: 'abc', language: 'md' });
    expect(root.querySelector('.cm-editor')).not.toBeNull();
    handle.destroy();
    expect(root.querySelector('.cm-editor')).toBeNull();
    expect(mock.hasHandler).toBe(false);
  });

  it('destroy clears the module port so a later openExternal is a no-op', () => {
    const mock = mockPort();
    const handle = mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text: 'x', language: 'md' });
    handle.destroy();
    const sentBefore = mock.sent.length;
    openExternal('https://example.com');
    expect(mock.sent.length).toBe(sentBefore);
  });

  // Two mounts on one page: destroying the first must not sever the second's
  // openExternal path (destroy() only clears the module port when it still
  // points at its own port — see clearPort in host-port.ts).
  it('destroying one mount leaves a second mount\'s openExternal working', () => {
    const mockA = mockPort();
    const mockB = mockPort();
    const rootB = document.createElement('div');
    document.body.appendChild(rootB);

    const handleA = mountEditor({ root, port: mockA.port });
    const handleB = mountEditor({ root: rootB, port: mockB.port });
    mockA.push({ type: 'init', text: 'a', language: 'md' });
    mockB.push({ type: 'init', text: 'b', language: 'md' });

    handleA.destroy();
    openExternal('https://example.com');
    expect(mockB.sent).toContainEqual({
      type: 'open-external',
      url: 'https://example.com',
    });
    expect(mockA.sent.some((m) => m.type === 'open-external')).toBe(false);

    // Once the last mount is gone, openExternal is a no-op again.
    handleB.destroy();
    const after = mockB.sent.length;
    openExternal('https://example.com');
    expect(mockB.sent.length).toBe(after);
  });

  // Host-sync `update`s are remote-annotated: even when the synced diff
  // leaves an auto-snippet trigger right before the cursor, no expansion
  // may fire (audit M-18 — a sync used to be able to rewrite itself).
  it('a host update completing an auto trigger does not expand a snippet', () => {
    const mock = mockPort();
    mountEditor({ root, port: mock.port });
    mock.push({
      type: 'hsnips',
      content: 'snippet te "text" A\n\\text{$0}\nendsnippet\n',
    });
    mock.push({ type: 'init', text: 'e', language: 'md' });
    // Cursor after the 'e'; the sync inserts 't' at 0, mapping the cursor to
    // sit right after the now-complete trigger 'te'.
    cmView().dispatch({ selection: { anchor: 1 } });
    mock.push({ type: 'update', text: 'te' });
    expect(cmView().state.doc.toString()).toBe('te');
  });

  // `hsnips` used to be dropped when no view existed yet; it must buffer like
  // `editor-config` and apply to the next `init`-built view (and re-apply
  // after every re-init, since snippets live in the view's state).
  it('buffers hsnips sent before init and applies them on init', () => {
    const mock = mockPort();
    mountEditor({ root, port: mock.port });
    mock.push({
      type: 'hsnips',
      content: 'snippet hi "greeting" A\nhello world\nendsnippet\n',
    });
    mock.push({ type: 'init', text: '', language: 'md' });
    const snippets = cmView().state.field(hsnipsTesting.snippetsField);
    expect(snippets.map((s) => s.trigger)).toContain('hi');

    // A re-init rebuilds the view; the buffered snippets must survive it.
    mock.push({ type: 'init', text: 'again', language: 'md' });
    const after = cmView().state.field(hsnipsTesting.snippetsField);
    expect(after.map((s) => s.trigger)).toContain('hi');
  });

  // The clipboard bridge (window.__chalkEditor) the native host calls into to
  // write UIPasteboard directly, since WebKit's own copy path doesn't reach the
  // system pasteboard on Catalyst. Reads/writes go through these two methods.
  const cmView = () =>
    EditorView.findFromDOM(root.querySelector('.cm-editor') as HTMLElement)!;

  it('getSelectionText slices the selection from editor state', () => {
    const mock = mockPort();
    const handle = mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text: 'hello world', language: 'md' });
    cmView().dispatch({ selection: { anchor: 0, head: 5 } });
    expect(handle.getSelectionText()).toBe('hello');
  });

  it('getSelectionText is empty for a collapsed selection', () => {
    const mock = mockPort();
    const handle = mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text: 'hello world', language: 'md' });
    cmView().dispatch({ selection: { anchor: 4 } });
    expect(handle.getSelectionText()).toBe('');
  });

  it('replaceSelection deletes the selection and flushes an edit', () => {
    const mock = mockPort();
    const handle = mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text: 'hello world', language: 'md' });
    cmView().dispatch({ selection: { anchor: 0, head: 6 } }); // 'hello '
    handle.replaceSelection('');
    expect(cmView().state.doc.toString()).toBe('world');
    expect(mock.sent).toContainEqual({ type: 'edit', text: 'world' });
  });

  // The C-5 epoch echo: the host stamps text pushes so it can drop edit
  // echoes that predate a buffer swap (keystroke racing a tab switch).
  it('echoes the epoch from the last applied init/update on every edit', () => {
    const mock = mockPort();
    const handle = mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text: 'one', language: 'md', epoch: 4 });
    cmView().dispatch({ selection: { anchor: 3 } });
    handle.replaceSelection('!');
    expect(mock.sent).toContainEqual({ type: 'edit', text: 'one!', epoch: 4 });

    // An update bumps the generation even when its text is identical to the
    // current doc (the early-return path must still record the epoch).
    mock.push({ type: 'update', text: 'one!', epoch: 5 });
    handle.replaceSelection('?');
    expect(mock.sent).toContainEqual({ type: 'edit', text: 'one!?', epoch: 5 });
  });

  it('sends edits without an epoch field for hosts that never stamp (VS Code)', () => {
    const mock = mockPort();
    const handle = mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text: 'plain', language: 'md' });
    cmView().dispatch({ selection: { anchor: 5 } });
    handle.replaceSelection('.');
    const edit = mock.sent.find((m) => m.type === 'edit');
    expect(edit).toEqual({ type: 'edit', text: 'plain.' });
    expect(edit && 'epoch' in edit).toBe(false);
  });

  // VS Code sends a CRLF file's text as-is; CM6 stores LF. An identical push
  // must not read as a change, rewrite the doc, move the caret or echo back.
  it('treats a CRLF update identical to the CRLF init as a no-op', () => {
    const mock = mockPort();
    mountEditor({ root, port: mock.port });
    const text = 'first line\r\nsecond line\r\nthird\r\n';
    mock.push({ type: 'init', text, language: 'md' });
    cmView().dispatch({ selection: { anchor: 15 } });
    const before = cmView().state.doc;
    mock.push({ type: 'update', text });
    expect(cmView().state.doc).toBe(before);
    expect(cmView().state.selection.main.head).toBe(15);
    expect(mock.sent.filter((m) => m.type === 'edit')).toEqual([]);
  });

  it('a CRLF update applies only its real change', () => {
    const mock = mockPort();
    mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text: 'a\r\nb\r\nc', language: 'md' });
    mock.push({ type: 'update', text: 'a\r\nB\r\nc' });
    expect(cmView().state.doc.toString()).toBe('a\nB\nc');
    expect(mock.sent.filter((m) => m.type === 'edit')).toEqual([]);
  });

  it('a config push reconfigures only what changed', () => {
    const mock = mockPort();
    mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text: 'x', language: 'md' });
    const view = cmView();
    const specs: Array<{ effects?: unknown[] }> = [];
    const realDispatch = view.dispatch.bind(view);
    view.dispatch = ((...args: unknown[]) => {
      specs.push(args[0] as (typeof specs)[number]);
      return (realDispatch as (...a: unknown[]) => void)(...args);
    }) as typeof view.dispatch;
    const themes = vi.spyOn(EditorView, 'theme');

    mock.push({ type: 'editor-config', config: { ...defaultEditorConfig } });
    expect(specs).toHaveLength(0);

    mock.push({ type: 'editor-config', config: { ...defaultEditorConfig, editingMode: 'typewriter' } });
    expect(specs).toHaveLength(1);
    expect(specs[0].effects).toHaveLength(1);
    expect(themes).not.toHaveBeenCalled();

    // A theme field builds its rules once, however often it is pushed.
    const wide = { ...defaultEditorConfig, editingMode: 'typewriter' as const, wordWrapColumn: 91 };
    mock.push({ type: 'editor-config', config: wide });
    mock.push({ type: 'editor-config', config: { ...defaultEditorConfig, editingMode: 'typewriter' } });
    mock.push({ type: 'editor-config', config: wide });
    expect(themes).toHaveBeenCalledTimes(1);
    themes.mockRestore();
  });

  it('getOutlineSnapshot returns the empty snapshot before init', () => {
    const mock = mockPort();
    const handle = mountEditor({ root, port: mock.port });
    expect(handle.getOutlineSnapshot()).toEqual({ items: [], cursorLine: 1 });
  });

  it('getOutlineSnapshot pairs the outline with the cursor line', () => {
    const mock = mockPort();
    const handle = mountEditor({ root, port: mock.port });
    mock.push({
      type: 'init',
      text: '\\section{Intro}\nbody\n\\section{Method}\nmore',
      language: 'tex',
    });
    cmView().dispatch({ selection: { anchor: cmView().state.doc.line(4).from } });
    const snap = handle.getOutlineSnapshot();
    expect(snap.cursorLine).toBe(4);
    expect(snap.items.map((i) => [i.kind, i.title, i.line])).toEqual([
      ['heading', 'Intro', 1],
      ['heading', 'Method', 3],
    ]);
  });

  // jsdom can't measure scroll geometry; lock the dispatch shape instead — the
  // section jump must carry a scrollIntoView *effect* (y:'start' placement),
  // not the plain `scrollIntoView: true` nearest-edge form.
  it('gotoLine sets the selection and dispatches a scroll effect', () => {
    const mock = mockPort();
    const handle = mountEditor({ root, port: mock.port });
    mock.push({ type: 'init', text: 'one\ntwo\nthree', language: 'md' });

    const view = cmView();
    const specs: Array<{ selection?: unknown; effects?: unknown }> = [];
    const realDispatch = view.dispatch.bind(view);
    view.dispatch = ((...args: unknown[]) => {
      specs.push(args[0] as (typeof specs)[number]);
      return (realDispatch as (...a: unknown[]) => void)(...args);
    }) as typeof view.dispatch;

    handle.gotoLine(2);

    expect(specs).toHaveLength(1);
    expect(specs[0].effects).toBeTruthy();
    expect(view.state.selection.main.head).toBe(view.state.doc.line(2).from);
  });
});
