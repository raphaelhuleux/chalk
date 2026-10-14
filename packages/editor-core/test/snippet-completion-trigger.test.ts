import { describe, it, expect } from 'vitest';
import { EditorView } from '@codemirror/view';
import {
  acceptCompletion,
  CompletionContext,
  completionStatus,
  currentCompletions,
  setSelectedCompletion,
} from '@codemirror/autocomplete';
import { langView } from './helpers/views';
import { mdCompletionSource } from '../src/editor/md-completions';
import { latexCompletionSource } from '../src/editor/latex-completions';
import { insertSnippetBody } from '../src/editor/hsnips-plugin';
import type { WorkspaceAccess } from '../src/editor/workspace-files';

/**
 * A snippet that drops the caret into an argument must offer what goes there.
 *
 * CM6's autocompletion is keystroke-driven, so landing on a tab stop opened
 * nothing: the figure snippet writes `![]()` for you, which means you never
 * type the `(` that would have triggered the file list, and the slot sat
 * silent until you typed a character into it.
 *
 * The rule these pin: ARGUMENT positions auto-offer (file paths, `\ref{`,
 * `\begin{`), line-start ones do not (a callout fence, a code fence, a
 * frontmatter key) — you are naming those, not picking from a list.
 */
const FILES: WorkspaceAccess = {
  list: async (kinds) =>
    kinds.includes('image') ? ['figures/growth.png', 'diagram.pdf'] : ['notes.md'],
  readText: async () => null,
};

const makeView = (doc: string, language: 'md' | 'tex'): EditorView =>
  langView(doc, language, { workspaceAccess: FILES });

/** Apply a named option from the language's own source, as CM6 would. */
function applyCompletion(view: EditorView, language: 'md' | 'tex', label: string): void {
  const pos = view.state.selection.main.head;
  const source = language === 'md' ? mdCompletionSource : latexCompletionSource;
  const result = source(new CompletionContext(view.state, pos, false));
  if (!result || result instanceof Promise) throw new Error('expected a sync result');
  const option = result.options.find((o) => o.label === label);
  if (!option) throw new Error(`no option ${label}`);
  if (typeof option.apply === 'function') option.apply(view, option, result.from, pos);
  else view.dispatch({ changes: { from: result.from, to: pos, insert: option.label } });
}

function pressTab(view: EditorView): void {
  view.contentDOM.dispatchEvent(
    new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true }),
  );
}

/** Past CM6's ~50ms completion debounce, plus the async file listing. */
const settle = (): Promise<void> => new Promise((r) => setTimeout(r, 150));

describe('completion on snippet tab stops', () => {
  it('offers images when Tab lands in the figure snippet image path', async () => {
    const view = makeView('::: ', 'md');
    view.dispatch({ selection: { anchor: 4 } });
    applyCompletion(view, 'md', 'figure');

    // First stop is the label slug — you are naming it, so nothing opens.
    await settle();
    expect(completionStatus(view.state)).toBeNull();

    pressTab(view); // → the `![]()` slot
    await settle();
    expect(view.state.doc.lineAt(view.state.selection.main.head).text).toContain('![](');
    expect(completionStatus(view.state)).toBe('active');
    expect(currentCompletions(view.state).map((c) => c.label)).toContain('figures/growth.png');
    view.destroy();
  });

  it('offers files when Tab lands in \\includegraphics{}', async () => {
    const view = makeView('\\includeg', 'tex');
    view.dispatch({ selection: { anchor: 9 } });
    applyCompletion(view, 'tex', '\\includegraphics');

    pressTab(view); // width → the path braces
    await settle();
    expect(completionStatus(view.state)).toBe('active');
    expect(currentCompletions(view.state).map((c) => c.label)).toContain('figures/growth.png');
    view.destroy();
  });

  it('offers environments when Tab lands in \\begin{}', async () => {
    const view = makeView('\\beg', 'tex');
    view.dispatch({ selection: { anchor: 4 } });
    applyCompletion(view, 'tex', '\\begin');
    await settle();
    expect(completionStatus(view.state)).toBe('active');
    expect(currentCompletions(view.state).map((c) => c.label)).toContain('itemize');
    view.destroy();
  });

  it('Tab accepts the open completion before advancing the session', async () => {
    const view = makeView('\\label{eq:euler}\n', 'tex');
    const end = view.state.doc.length;
    view.dispatch({ selection: { anchor: end } });
    insertSnippetBody(view, end, end, '\\ref{$1} and $2$0');
    await settle();
    await settle(); // past CM6's interactionDelay, which gates acceptCompletion
    expect(completionStatus(view.state)).toBe('active');
    pressTab(view);
    expect(view.state.doc.line(2).text).toBe('\\ref{eq:euler} and ');
    pressTab(view); // the popup is closed now, so Tab moves on to $2
    expect(view.state.selection.main.head).toBe(view.state.doc.length);
    view.destroy();
  });

  it('accepting a snippet completion closes its popup, so Tab moves on', async () => {
    const view = makeView('', 'md');
    view.dispatch({ changes: { from: 0, insert: '::: ' }, selection: { anchor: 4 }, userEvent: 'input.type' });
    await settle();
    await settle(); // past CM6's interactionDelay, which gates acceptCompletion
    const figure = currentCompletions(view.state).findIndex((c) => c.label === 'figure');
    expect(figure).toBeGreaterThanOrEqual(0);
    view.dispatch({ effects: setSelectedCompletion(figure) });
    expect(acceptCompletion(view)).toBe(true);
    // The first stop is the label slug: a placeholder you type over, no list.
    expect(completionStatus(view.state)).toBeNull();
    pressTab(view);
    expect(view.state.doc.lineAt(view.state.selection.main.head).text).toContain('![](');
    expect(view.state.doc.toString().match(/!\[\]\(/g)).toHaveLength(1);
    view.destroy();
  });

  it('stays quiet when a stop lands in ordinary prose', async () => {
    const view = makeView('', 'md');
    insertSnippetBody(view, 0, 0, 'Dear $1,\n\n$0');
    await settle();
    expect(completionStatus(view.state)).toBeNull();
    view.destroy();
  });
});

describe('completion when the caret moves into an empty argument', () => {
  /** Move the caret the way a click or an arrow key would: selection only. */
  function moveCaret(view: EditorView, pos: number): void {
    view.dispatch({ selection: { anchor: pos } });
  }

  it('offers images when the caret enters an empty image path', async () => {
    const view = makeView('![]()', 'md');
    moveCaret(view, 4);
    await settle();
    expect(completionStatus(view.state)).toBe('active');
    expect(currentCompletions(view.state).map((c) => c.label)).toContain('figures/growth.png');
    view.destroy();
  });

  it('stays quiet when the path already has content', async () => {
    // Clicking into a written path means editing it, not picking from a list.
    const view = makeView('![](figures/growth.png)', 'md');
    moveCaret(view, 8);
    await settle();
    expect(completionStatus(view.state)).toBeNull();
    view.destroy();
  });

  it('offers files when the caret enters an empty \\includegraphics{}', async () => {
    const view = makeView('\\includegraphics{}', 'tex');
    moveCaret(view, '\\includegraphics{'.length);
    await settle();
    expect(completionStatus(view.state)).toBe('active');
    view.destroy();
  });

  it('offers labels when the caret enters an empty \\ref{}', async () => {
    const view = makeView('\\label{eq:euler}\n\\ref{}', 'tex');
    moveCaret(view, view.state.doc.length - 1);
    await settle();
    expect(completionStatus(view.state)).toBe('active');
    expect(currentCompletions(view.state).map((c) => c.label)).toContain('eq:euler');
    view.destroy();
  });

  it('stays quiet on an ordinary caret move', async () => {
    const view = makeView('some prose here', 'md');
    moveCaret(view, 5);
    await settle();
    expect(completionStatus(view.state)).toBeNull();
    view.destroy();
  });

  it('stays quiet on a callout fence line, which is not an argument', async () => {
    // Line-start sources are for text you are writing, not a slot you are
    // filling; opening a list because the caret passed by would be noise.
    const view = makeView('::: \nbody\n', 'md');
    moveCaret(view, 4);
    await settle();
    expect(completionStatus(view.state)).toBeNull();
    view.destroy();
  });
});
