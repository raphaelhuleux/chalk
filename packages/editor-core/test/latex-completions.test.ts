import { describe, it, expect } from 'vitest';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { CompletionContext, type CompletionResult } from '@codemirror/autocomplete';
import { latexCompletionSource } from '../src/editor/latex-completions';
import { texView } from './helpers/views';
import { setSnippets } from '../src/editor/hsnips-plugin';
import { parseHSnips } from '../src/editor/hsnips-parser';
import { undo } from '@codemirror/commands';

/**
 * The tex completion source, driven directly. `|` marks the caret.
 *
 * The popup's contract after the 2026-08 narrowing: it never fires inside
 * math (that's hsnips' ground), a bare `\` offers text-mode commands only,
 * and `{`-triggered argument completion works anywhere because typing
 * `\begin{` is an explicit request.
 */
function completeAt(
  docWithCaret: string,
): CompletionResult | Promise<CompletionResult | null> | null {
  const pos = docWithCaret.indexOf('|');
  if (pos < 0) throw new Error('test doc needs a | caret marker');
  const doc = docWithCaret.slice(0, pos) + docWithCaret.slice(pos + 1);
  const state = EditorState.create({ doc, selection: { anchor: pos } });
  return latexCompletionSource(new CompletionContext(state, pos, false));
}

/** Sync branches only — `\cite{` and the file arguments return a Promise,
 *  and those are exercised in workspace-completions.test.ts. */
function labelsAt(docWithCaret: string): string[] {
  const result = completeAt(docWithCaret);
  if (result instanceof Promise) throw new Error('use completeAt + await for async branches');
  return result ? result.options.map((o) => o.label) : [];
}

describe('text-mode command completion', () => {
  it('offers \\section for a bare \\sec in text mode', () => {
    expect(labelsAt('\\sec|')).toContain('\\section');
  });

  it('offers nothing inside inline math', () => {
    expect(labelsAt('text $x + \\sec|$ more')).toEqual([]);
  });

  it('offers nothing inside display math', () => {
    expect(labelsAt('$$\n  \\sec|\n$$')).toEqual([]);
  });

  it('offers nothing inside a math environment', () => {
    expect(labelsAt('\\begin{align}\n  \\sec|\n\\end{align}')).toEqual([]);
  });

  it('drops the math symbols entirely — hsnips owns those', () => {
    const everything = labelsAt('\\|');
    expect(everything).not.toContain('\\alpha');
    expect(everything).not.toContain('\\frac');
    expect(everything).not.toContain('\\mathbb');
    expect(everything).not.toContain('\\left');
  });

  it('offers \\begin, which the old list omitted', () => {
    expect(labelsAt('\\beg|')).toContain('\\begin');
  });

  it('offers nothing inside a LaTeX comment', () => {
    expect(labelsAt('% see \\sec|')).toEqual([]);
  });

  it('completes after an escaped percent, which does not start a comment', () => {
    expect(labelsAt('100\\% of \\sec|')).toContain('\\section');
  });

  it('offers nothing after `\\\\%`, an escaped backslash then a comment', () => {
    expect(labelsAt('a\\\\% see \\sec|')).toEqual([]);
  });
});

// ── Insertion behavior ──────────────────────────────────────────────
//
// Applying a completion runs through the hsnips engine, so these need a
// real view with the tex extension set (the snippet session lives in a
// StateField that `insertSnippetBody` writes to).

/** Mount the doc with the caret where the `|` marker sat. */
function viewAt(docWithCaret: string): EditorView {
  const pos = docWithCaret.indexOf('|');
  if (pos < 0) throw new Error('test doc needs a | caret marker');
  const doc = docWithCaret.slice(0, pos) + docWithCaret.slice(pos + 1);
  return texView(doc, { cursor: pos });
}

/** Apply the named completion at the caret, the way CM6's `applyCompletion`
 *  would: look the option up in the source's result and call its `apply`
 *  with the result's own `from`/`to`. */
function applyCompletion(view: EditorView, label: string): void {
  const pos = view.state.selection.main.head;
  const result = latexCompletionSource(new CompletionContext(view.state, pos, false));
  if (!result) throw new Error(`no completions at ${pos}`);
  if (result instanceof Promise) throw new Error('applyCompletion covers the sync branches only');
  const option = result.options.find((o) => o.label === label);
  if (!option) throw new Error(`no option ${label} (got ${result.options.map((o) => o.label).join(', ')})`);
  // Same dispatch CM6's own applyCompletion makes: a function apply owns the
  // transaction, anything else is a literal insertion of the string or label.
  if (typeof option.apply === 'function') option.apply(view, option, result.from, pos);
  else view.dispatch({ changes: { from: result.from, to: pos, insert: option.apply ?? option.label } });
}

function pressTab(view: EditorView) {
  view.contentDOM.dispatchEvent(
    new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true }),
  );
}

describe('applying a command completion', () => {
  it('lands the caret inside the braces, with no literal $1', () => {
    const view = viewAt('\\sec|');
    applyCompletion(view, '\\section');
    expect(view.state.doc.toString()).toBe('\\section{}');
    expect(view.state.selection.main.head).toBe('\\section{'.length);
    view.destroy();
  });

  it('mirrors the environment name from \\begin into \\end', () => {
    const view = viewAt('\\beg|');
    applyCompletion(view, '\\begin');
    expect(view.state.doc.toString()).toBe('\\begin{}\n    \n\\end{}');
    view.dispatch({ changes: { from: view.state.selection.main.head, insert: 'proof' } });
    expect(view.state.doc.toString()).toBe('\\begin{proof}\n    \n\\end{proof}');
    view.destroy();
  });

  it('inserts a real backslash before the new command name', () => {
    const view = viewAt('\\newc|');
    applyCompletion(view, '\\newcommand');
    expect(view.state.doc.toString()).toBe('\\newcommand{\\}{}');
    view.destroy();
  });
});

describe('applying an environment completion', () => {
  it('fills the figure boilerplate and steps through its tab stops', () => {
    const view = viewAt('\\begin{fig|');
    applyCompletion(view, 'figure');
    expect(view.state.doc.toString()).toBe(
      '\\begin{figure}[htbp]\n' +
        '    \\centering\n' +
        '    \\includegraphics[width=0.8\\textwidth]{}\n' +
        '    \\caption{}\n' +
        '    \\label{fig:}\n' +
        '\\end{figure}',
    );
    const caret = view.state.selection.main.head;
    expect(view.state.sliceDoc(caret - 1, caret + 1)).toBe('{}');
    expect(view.state.sliceDoc(0, caret)).toContain('\\includegraphics');

    pressTab(view);
    const afterFirstTab = view.state.selection.main.head;
    expect(view.state.sliceDoc(0, afterFirstTab)).toContain('\\caption{');
    view.destroy();
  });

  it('consumes the auto-closed brace instead of leaving a stray one', () => {
    const view = viewAt('\\begin{ali|}');
    applyCompletion(view, 'align');
    expect(view.state.doc.toString()).toBe('\\begin{align}\n    \n\\end{align}');
    view.destroy();
  });

  it('emits a two-backslash row break in cases, not four', () => {
    const view = viewAt('\\begin{cas|');
    applyCompletion(view, 'cases');
    const rowBreak = view.state.doc.toString().split('\n').find((l) => l.includes('\\\\'));
    expect(rowBreak?.trim()).toBe('& \\\\');
    view.destroy();
  });

  it('fills only the name after \\end, leaving the document alone', () => {
    const view = viewAt('\\begin{align}\n\n\\end{ali|}');
    applyCompletion(view, 'align');
    expect(view.state.doc.toString()).toBe('\\begin{align}\n\n\\end{align}');
    view.destroy();
  });

  it('offers pmatrix for a mid-word prefix, leaving the ranking to CM6', () => {
    expect(labelsAt('\\begin{mat|')).toContain('pmatrix');
  });
});

describe('cross-reference arguments', () => {
  const DOC =
    '\\section{Intro}\\label{sec:intro}\n' +
    '\\begin{equation}\\label{eq:euler}\\end{equation}\n' +
    '\\begin{thebibliography}{9}\n' +
    '\\bibitem{knuth} Knuth\n' +
    '\\end{thebibliography}\n';

  it('offers document labels after \\ref{', () => {
    expect(labelsAt(DOC + '\\ref{|')).toEqual(
      expect.arrayContaining(['sec:intro', 'eq:euler']),
    );
  });

  it('offers document labels after \\eqref{', () => {
    expect(labelsAt(DOC + '\\eqref{|')).toContain('eq:euler');
  });

  // `\cite{` is the one async branch: it merges in-document `\bibitem` keys
  // with the keys in every `.bib` the host lists (see workspace-completions).
  it('offers bibliography keys after \\cite{, and only those', async () => {
    const result = await completeAt(DOC + '\\cite{|');
    const keys = (result?.options ?? []).map((o) => o.label);
    expect(keys).toContain('knuth');
    expect(keys).not.toContain('eq:euler');
  });

  it('offers prefix conventions after \\label{, not existing labels', () => {
    const offered = labelsAt(DOC + '\\label{|');
    expect(offered).toEqual(expect.arrayContaining(['fig:', 'eq:', 'tab:', 'sec:']));
    expect(offered).not.toContain('eq:euler');
  });

  it('keeps offering labels once part of the key is typed', () => {
    expect(labelsAt(DOC + '\\ref{eq|')).toContain('eq:euler');
  });

  it('completes a label without swallowing the following text', () => {
    const view = viewAt(DOC + 'see \\ref{eq|} above');
    applyCompletion(view, 'eq:euler');
    expect(view.state.doc.toString()).toContain('see \\ref{eq:euler} above');
    view.destroy();
  });

  it('stays quiet for arguments that are not references', () => {
    expect(labelsAt(DOC + '\\caption{|')).toEqual([]);
  });
});

describe('interaction with the snippet engine', () => {
  it('undoes a whole completion insertion with one Cmd+Z', () => {
    const view = viewAt('\\sec|');
    applyCompletion(view, '\\section');
    expect(view.state.doc.toString()).toBe('\\section{}');
    undo(view);
    expect(view.state.doc.toString()).toBe('\\sec');
    view.destroy();
  });

  it('leaves snippet auto-expansion working after an insertion', () => {
    // insertSnippetBody raises a module-level `isExpanding` flag to keep the
    // auto-expand listener from re-entering. Drop its `finally` and every
    // snippet in the session goes inert after the first completion.
    const view = viewAt('\\sec|');
    view.dispatch({
      effects: setSnippets.of(parseHSnips('snippet ;a "alpha" iA\n\\alpha\nendsnippet\n')),
    });
    applyCompletion(view, '\\section');
    // One char per transaction, cursor-advancing: the auto-expand listener
    // only reacts to single-character keystrokes.
    for (const ch of ';a') view.dispatch(view.state.replaceSelection(ch));
    expect(view.state.doc.toString()).toContain('\\alpha');
    view.destroy();
  });
});
