import { describe, it, expect, afterEach } from 'vitest';
import { EditorView } from '@codemirror/view';
import { selectCharLeft } from '@codemirror/commands';
import type { Language } from '../src/editor/setup';
import { destroyViews, langView } from './helpers/views';

/**
 * Selecting inside a concealed construct must not re-conceal it under the
 * selection.
 *
 * A concealed construct replaces part of its source, and a replace decoration
 * has no DOM position inside it. When a selection end lands in a replaced
 * range, CM6 resolves it to the range's outer edge: the caret visibly leaves
 * the construct and the next keystroke is inserted there instead of replacing
 * the selection. Reported for inline math (Shift/Option+Arrow inside
 * `$E_{z_{t+1}}$` ejected the caret past the closing `$`), then found in every
 * construct of the family — including the ones that hide only their
 * delimiters, where a selection inside `\textbf{` typed over the wrong text.
 *
 * The STATE selection is correct throughout, so these tests assert the cause
 * (the source stays on screen) rather than the DOM symptom; the symptom itself
 * is pinned in the browser harness, which can see a real caret.
 *
 * The contract in the other direction is asserted too: a selection on a
 * construct's VISIBLE text strands nothing, so it must keep the concealed
 * form. That is what the pointer-gesture double-click contracts rest on.
 */

const mount = (doc: string, caret: number, language: Language): EditorView =>
  langView(doc, language, { ensureTree: true, cursor: caret });

afterEach(destroyViews);

const text = (view: EditorView) => view.dom.querySelector('.cm-content')!.textContent ?? '';

/** Caret at `caret`, then Shift+Left `n` times — what the bug reports do. */
function selectLeft(view: EditorView, n: number): void {
  for (let i = 0; i < n; i++) selectCharLeft(view);
  expect(view.state.selection.main.empty).toBe(false);
}

describe('tex constructs stay revealed under a selection inside them', () => {
  it('a \\ref pill keeps its source while the selection is in the key', () => {
    const doc = 'See \\ref{eq:main} now.';
    const view = mount(doc, doc.indexOf('main') + 2, 'tex');
    expect(text(view)).toContain('\\ref{eq:main}');
    selectLeft(view, 2);
    expect(text(view)).toContain('\\ref{eq:main}');
  });

  it('\\textbf keeps its source while the selection is in the command name', () => {
    // The whole `\textbf{` prefix is replaced when concealed, so a selection
    // inside it is stranded just as badly as one inside a formula.
    const doc = 'A \\textbf{word} here.';
    const view = mount(doc, doc.indexOf('textbf') + 2, 'tex');
    selectLeft(view, 2);
    expect(text(view)).toContain('\\textbf{');
  });

  it('\\textbf re-conceals for a selection on its visible argument', () => {
    // The double-click word-select case: both ends sit on text that is on
    // screen either way, so nothing is stranded and nothing may reflow.
    const doc = 'A \\textbf{word} here.';
    const view = mount(doc, doc.indexOf('word') + 4, 'tex');
    expect(text(view)).toContain('\\textbf{');
    for (let i = 0; i < 4; i++) selectCharLeft(view);
    expect(view.state.selection.main.from).toBe(doc.indexOf('word'));
    expect(text(view)).not.toContain('\\textbf{');
  });

  it('\\includegraphics keeps its source while the selection is in the path', () => {
    const doc = 'Fig: \\includegraphics{a.png} end.';
    const view = mount(doc, doc.indexOf('a.png') + 3, 'tex');
    selectLeft(view, 2);
    expect(text(view)).toContain('\\includegraphics{');
  });

  it('an \\item marker keeps its source while the selection is in the token', () => {
    const doc = '\\begin{itemize}\n\\item one\n\\end{itemize}\n';
    const view = mount(doc, doc.indexOf('\\item') + 3, 'tex');
    expect(text(view)).toContain('\\item');
    selectLeft(view, 2);
    expect(text(view)).toContain('\\item');
  });
});

describe('md constructs stay revealed under a selection inside them', () => {
  it('bold keeps its markers while the selection is inside one', () => {
    // Caret between the two opening asterisks. Re-hiding both markers made the
    // keystroke replace `**` instead of the single `*` that was selected.
    const doc = 'A **bold** word.';
    const view = mount(doc, doc.indexOf('**') + 1, 'md');
    selectLeft(view, 1);
    expect(text(view)).toContain('**');
  });

  it('bold re-conceals for a selection on the word itself', () => {
    const doc = 'A **bold** word.';
    const view = mount(doc, doc.indexOf('bold') + 4, 'md');
    for (let i = 0; i < 4; i++) selectCharLeft(view);
    expect(view.state.selection.main.from).toBe(doc.indexOf('bold'));
    expect(text(view)).not.toContain('**');
  });

  it('an image keeps its source while the selection is in the path', () => {
    const doc = 'Fig ![alt](a.png) end.';
    const view = mount(doc, doc.indexOf('a.png') + 3, 'md');
    selectLeft(view, 2);
    expect(text(view)).toContain('![alt](a.png)');
  });

  it('a heading id keeps its source while the selection is in the id', () => {
    const doc = '# Title {#sec-one}\n\nbody\n';
    const view = mount(doc, doc.indexOf('sec-one') + 3, 'md');
    expect(text(view)).toContain('{#sec-one}');
    selectLeft(view, 2);
    expect(text(view)).toContain('{#sec-one}');
  });

  it('a heading re-conceals its id for a selection in the heading text', () => {
    const doc = '# Title {#sec-one}\n\nbody\n';
    const view = mount(doc, doc.indexOf('Title') + 5, 'md');
    for (let i = 0; i < 5; i++) selectCharLeft(view);
    expect(text(view)).not.toContain('{#sec-one}');
  });

  it('a crossref pill keeps its source while the selection is in the key', () => {
    const doc = 'See @eq-ols here.\n\n$$\nx\n$$ {#eq-ols}';
    const view = mount(doc, doc.indexOf('@eq-ols') + 4, 'md');
    expect(text(view)).toContain('@eq-ols');
    selectLeft(view, 2);
    expect(text(view)).toContain('@eq-ols');
  });
});
