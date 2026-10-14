import { describe, it, expect } from 'vitest';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { CompletionContext, type CompletionResult } from '@codemirror/autocomplete';
import { mdCompletionSource } from '../src/editor/md-completions';
import { parseFenceOpen } from '../src/editor/md-callout-plugin';
import { mdView } from './helpers/views';

/**
 * The markdown completion source, driven directly. `|` marks the caret.
 *
 * Markdown gets no bare-`\` branch: outside math is prose, where a LaTeX
 * command is not valid text. What it gets instead is the structure it has
 * that tex does not — Quarto callout fences, `@` cross-references and code
 * fences.
 */
/** Sync branches only — link paths need a host and return a Promise; those
 *  live in workspace-completions.test.ts. */
function completeAt(docWithCaret: string): CompletionResult | null {
  const pos = docWithCaret.indexOf('|');
  if (pos < 0) throw new Error('test doc needs a | caret marker');
  const doc = docWithCaret.slice(0, pos) + docWithCaret.slice(pos + 1);
  const state = EditorState.create({ doc, selection: { anchor: pos } });
  const result = mdCompletionSource(new CompletionContext(state, pos, false));
  if (result instanceof Promise) throw new Error('use an await helper for async branches');
  return result;
}

function labelsAt(docWithCaret: string): string[] {
  const result = completeAt(docWithCaret);
  return result ? result.options.map((o) => o.label) : [];
}

/** Mount the doc with the caret where the `|` marker sat. */
function viewAt(docWithCaret: string): EditorView {
  const pos = docWithCaret.indexOf('|');
  const doc = docWithCaret.slice(0, pos) + docWithCaret.slice(pos + 1);
  return mdView(doc, { cursor: pos });
}

function applyCompletion(view: EditorView, label: string): void {
  const pos = view.state.selection.main.head;
  const result = mdCompletionSource(new CompletionContext(view.state, pos, false));
  if (!result) throw new Error(`no completions at ${pos}`);
  if (result instanceof Promise) throw new Error('applyCompletion covers the sync branches only');
  const option = result.options.find((o) => o.label === label);
  if (!option) throw new Error(`no option ${label} (got ${result.options.map((o) => o.label).join(', ')})`);
  if (typeof option.apply === 'function') option.apply(view, option, result.from, pos);
  else view.dispatch({ changes: { from: result.from, to: pos, insert: option.apply ?? option.label } });
}

describe('callout fences', () => {
  it('offers the theorem family and the admonitions after :::', () => {
    const offered = labelsAt('::: |');
    expect(offered).toEqual(
      expect.arrayContaining(['theorem', 'lemma', 'proof', 'remark', 'note', 'warning']),
    );
  });

  it('filters on the type word, not the whole fence line', () => {
    const result = completeAt('::: {#thm|');
    expect(result).not.toBeNull();
    expect(result!.from).toBe('::: {#'.length);
  });

  it('inserts a numbered callout the plugin can parse', () => {
    const view = viewAt('::: |');
    applyCompletion(view, 'theorem');
    const lines = view.state.doc.toString().split('\n');
    expect(parseFenceOpen(lines[0])).toMatchObject({ type: 'theorem' });
    expect(lines[lines.length - 1]).toBe(':::');
    view.destroy();
  });

  it('uses the class syntax for the unnumbered environments', () => {
    const view = viewAt('::: |');
    applyCompletion(view, 'proof');
    const open = view.state.doc.toString().split('\n')[0];
    expect(open).toBe('::: {.proof}');
    expect(parseFenceOpen(open)).toMatchObject({ type: 'proof' });
    view.destroy();
  });

  it('uses the callout- class for the Quarto admonitions', () => {
    const view = viewAt('::: |');
    applyCompletion(view, 'note');
    const open = view.state.doc.toString().split('\n')[0];
    expect(open).toBe('::: {.callout-note}');
    expect(parseFenceOpen(open)).toMatchObject({ type: 'note' });
    view.destroy();
  });

  it('rewrites a partly typed fence, with the slug selected for typing over', () => {
    const view = viewAt('::: {#thm|');
    applyCompletion(view, 'theorem');
    expect(view.state.doc.toString().split('\n')[0]).toBe('::: {#thm-label}');
    expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe(
      'label',
    );
    view.destroy();
  });

  it('leaves a closing ::: fence alone', () => {
    expect(labelsAt('::: {.proof}\nbody\n:::|')).toEqual([]);
  });
});

describe('cross-references', () => {
  const DOC = '::: {#thm-pythagoras}\nbody\n:::\n\n';

  it('offers document keys after @', () => {
    expect(labelsAt(DOC + 'see @thm|')).toContain('thm-pythagoras');
  });

  it('reports the resolved number as the detail', () => {
    const option = completeAt(DOC + 'see @thm|')!.options.find(
      (o) => o.label === 'thm-pythagoras',
    );
    expect(option?.detail).toContain('Theorem');
    expect(option?.detail).toContain('1');
  });

  it('stays quiet on a bare @, which is usually a handle', () => {
    expect(labelsAt(DOC + 'email @|')).toEqual([]);
  });

  it('replaces only the key, keeping the @', () => {
    const view = viewAt(DOC + 'see @thm|');
    applyCompletion(view, 'thm-pythagoras');
    expect(view.state.doc.toString()).toContain('see @thm-pythagoras');
    view.destroy();
  });
});

describe('code fences', () => {
  it('offers the languages that actually highlight', () => {
    expect(labelsAt('```|')).toEqual(expect.arrayContaining(['python', 'r', 'julia']));
  });

  it('offers the same set inside the Quarto brace form', () => {
    expect(labelsAt('```{r|')).toContain('r');
  });

  it('stays quiet on a closing fence', () => {
    expect(labelsAt('```python\ncode\n```|')).toEqual([]);
  });
});

describe('figure divs', () => {
  it('offers figure alongside the callout types', () => {
    expect(labelsAt('::: |')).toContain('figure');
  });

  it('inserts an image, a notes paragraph and a caption', () => {
    const view = viewAt('::: |');
    applyCompletion(view, 'figure');
    const lines = view.state.doc.toString().split('\n');
    expect(parseFenceOpen(lines[0])).toMatchObject({ type: 'figure' });
    expect(lines[1]).toMatch(/^!\[\]\(/);
    expect(lines.some((l) => l.startsWith('Notes:'))).toBe(true);
    expect(lines[lines.length - 1]).toBe(':::');
    view.destroy();
  });

  // quarto.org/docs/authoring/figures.html: "The last paragraph in the div
  // serves as the figure caption." Notes placed after it would silently
  // BECOME the caption, so the order is image → notes → caption.
  it('keeps the caption as the last paragraph, below the notes', () => {
    const view = viewAt('::: |');
    applyCompletion(view, 'figure');
    const body = view.state.doc.toString().split('\n').slice(0, -1);
    const notesAt = body.findIndex((l) => l.startsWith('Notes:'));
    const lastText = body.map((l) => l.trim()).filter(Boolean).length - 1;
    expect(notesAt).toBeGreaterThan(0);
    expect(body.filter(Boolean).indexOf(body[notesAt])).toBeLessThan(lastText);
    view.destroy();
  });

  it('puts the caret in the label slug first', () => {
    const view = viewAt('::: |');
    applyCompletion(view, 'figure');
    const sel = view.state.selection.main;
    expect(view.state.sliceDoc(sel.from, sel.to)).toBe('label');
    expect(view.state.doc.lineAt(sel.from).number).toBe(1);
    view.destroy();
  });
});
