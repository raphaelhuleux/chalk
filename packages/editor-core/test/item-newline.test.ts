import { describe, it, expect, beforeAll } from 'vitest';
import { EditorView } from '@codemirror/view';
import { EditorState, EditorSelection } from '@codemirror/state';
import {
  findEnclosingEnv,
  findMatchingEnd,
  itemEnterRun,
} from '../src/editor/item-newline';

function getter(lines: string[]) {
  return (n: number) => (n >= 1 && n <= lines.length ? lines[n - 1] : null);
}

describe('findEnclosingEnv', () => {
  it('finds the directly enclosing itemize', () => {
    const lines = [
      '\\begin{itemize}',
      '    \\item foo',
      '    \\item ',
      '\\end{itemize}',
    ];
    expect(findEnclosingEnv(getter(lines), 3)).toEqual({ name: 'itemize', line: 1 });
  });

  it('skips nested closed envs', () => {
    const lines = [
      '\\begin{enumerate}',
      '    \\item foo',
      '    \\begin{itemize}',
      '        \\item bar',
      '    \\end{itemize}',
      '    \\item ',
      '\\end{enumerate}',
    ];
    expect(findEnclosingEnv(getter(lines), 6)).toEqual({ name: 'enumerate', line: 1 });
  });

  it('finds the inner env when called from inside it', () => {
    const lines = [
      '\\begin{enumerate}',
      '    \\begin{itemize}',
      '        \\item ',
      '    \\end{itemize}',
      '\\end{enumerate}',
    ];
    expect(findEnclosingEnv(getter(lines), 3)).toEqual({ name: 'itemize', line: 2 });
  });

  it('returns null at top level', () => {
    const lines = ['no env here', '\\item orphan'];
    expect(findEnclosingEnv(getter(lines), 2)).toBeNull();
  });
});

describe('findMatchingEnd', () => {
  it('returns the matching end line', () => {
    const lines = [
      '\\begin{itemize}',
      '    \\item foo',
      '\\end{itemize}',
    ];
    expect(findMatchingEnd(getter(lines), 1, 'itemize', lines.length)).toBe(3);
  });

  it('skips inner same-named envs', () => {
    const lines = [
      '\\begin{itemize}',
      '    \\item outer',
      '    \\begin{itemize}',
      '        \\item inner',
      '    \\end{itemize}',
      '\\end{itemize}',
    ];
    expect(findMatchingEnd(getter(lines), 1, 'itemize', lines.length)).toBe(6);
  });

  it('returns null when no matching end exists', () => {
    const lines = ['\\begin{itemize}', '    \\item foo'];
    expect(findMatchingEnd(getter(lines), 1, 'itemize', lines.length)).toBeNull();
  });
});

// ---------------------------------------------------------------------------
//  Keymap-level behaviour (itemEnterRun)
// ---------------------------------------------------------------------------

beforeAll(() => {
  if (typeof Range.prototype.getClientRects !== 'function') {
    Range.prototype.getClientRects = () => [] as unknown as DOMRectList;
  }
  if (typeof Range.prototype.getBoundingClientRect !== 'function') {
    Range.prototype.getBoundingClientRect = () =>
      ({ x: 0, y: 0, width: 0, height: 0, top: 0, right: 0, bottom: 0, left: 0, toJSON: () => ({}) }) as DOMRect;
  }
});

function makeView(doc: string, cursor: number): EditorView {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  const state = EditorState.create({
    doc,
    selection: EditorSelection.cursor(cursor),
  });
  return new EditorView({ state, parent });
}

describe('itemEnterRun', () => {
  it('on a non-empty \\item: inserts "\\n<indent>\\item " at the cursor', () => {
    const doc = [
      '\\begin{itemize}',
      '    \\item foo',
      '\\end{itemize}',
    ].join('\n');
    // Cursor at end of "    \\item foo" — line index 2.
    const cursor = doc.indexOf('foo') + 3;
    const view = makeView(doc, cursor);
    const ok = itemEnterRun(view, () => false);
    expect(ok).toBe(true);
    expect(view.state.doc.toString()).toBe([
      '\\begin{itemize}',
      '    \\item foo',
      '    \\item ',
      '\\end{itemize}',
    ].join('\n'));
    // Cursor sits right after the newly-inserted "\\item ".
    expect(view.state.selection.main.head).toBe(
      view.state.doc.toString().indexOf('\\item ', view.state.doc.toString().indexOf('foo')) + '\\item '.length,
    );
    view.destroy();
  });

  it('on an empty \\item: deletes the line + opens a blank line after \\end{...}', () => {
    const doc = [
      '\\begin{itemize}',
      '    \\item foo',
      '    \\item ',
      '\\end{itemize}',
      'after',
    ].join('\n');
    const cursor = doc.indexOf('    \\item ', doc.indexOf('foo')) + '    \\item '.length;
    const view = makeView(doc, cursor);
    const ok = itemEnterRun(view, () => false);
    expect(ok).toBe(true);
    expect(view.state.doc.toString()).toBe([
      '\\begin{itemize}',
      '    \\item foo',
      '\\end{itemize}',
      '',
      'after',
    ].join('\n'));
    view.destroy();
  });

  it('falls through when the cursor sits before the \\item token', () => {
    const doc = ['\\begin{itemize}', '  \\item first', '  \\item second', '\\end{itemize}'].join('\n');
    const lineStart = doc.indexOf('  \\item second');
    for (const col of [0, 2, 4, 6]) {
      const view = makeView(doc, lineStart + col);
      expect(itemEnterRun(view, () => false), `column ${col}`).toBe(false);
      expect(view.state.doc.toString()).toBe(doc);
      view.destroy();
    }
  });

  it('continues when the cursor sits right after the \\item token', () => {
    const doc = '\\begin{itemize}\n  \\item second\n\\end{itemize}';
    const view = makeView(doc, doc.indexOf('\\item second') + '\\item'.length);
    expect(itemEnterRun(view, () => false)).toBe(true);
    expect(view.state.doc.line(3).text.startsWith('  \\item ')).toBe(true);
    view.destroy();
  });

  it('falls through when the cursor is in math context', () => {
    const view = makeView('    \\item ', 10);
    const ok = itemEnterRun(view, () => true);
    expect(ok).toBe(false);
    view.destroy();
  });

  it('falls through when the cursor line is not an \\item line', () => {
    const view = makeView('plain text line', 5);
    const ok = itemEnterRun(view, () => false);
    expect(ok).toBe(false);
    view.destroy();
  });

  it('falls through with a non-empty selection', () => {
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const state = EditorState.create({
      doc: '    \\item foo',
      selection: EditorSelection.range(0, 5),
    });
    const view = new EditorView({ state, parent });
    const ok = itemEnterRun(view, () => false);
    expect(ok).toBe(false);
    view.destroy();
  });

  it('empty \\item with no enclosing env falls through', () => {
    const view = makeView('    \\item ', 10);
    const ok = itemEnterRun(view, () => false);
    expect(ok).toBe(false);
    view.destroy();
  });
});
