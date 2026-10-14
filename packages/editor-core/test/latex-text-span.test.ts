import { describe, it, expect } from 'vitest';
import { EditorState, EditorSelection } from '@codemirror/state';
import { isInLatexTextSpan } from '../src/editor/latex-text-span';
import { parseHSnips } from '../src/editor/hsnips-parser';
import { isInMathContextTex } from '../src/editor/tex-math';
import { _testing } from '../src/editor/hsnips-plugin';

/**
 * `\text{…}` is prose punched into math. The bundled latex.hsnips says so
 * itself: its `math()` helper excludes `meta.text.normal.tex`. editor-core's
 * reimplementation dropped that, so typing `$\text{number}$` expanded `nu`
 * mid-word and produced `$\text{\numbers}$`.
 */
const at = (doc: string, pos: number) =>
  isInLatexTextSpan(EditorState.create({ doc }), pos);

describe('isInLatexTextSpan', () => {
  it('is true inside a \\text argument', () => {
    //           0123456789
    expect(at('$\\text{ab}$', 8)).toBe(true);
  });

  it('is false in plain math', () => {
    expect(at('$x + y$', 4)).toBe(false);
  });

  it('is false after the argument closes', () => {
    expect(at('$\\text{ab} + x$', 13)).toBe(false);
  });

  it('handles nested braces inside the argument', () => {
    const doc = '$\\text{a {b} c}$';
    expect(at(doc, doc.indexOf('c'))).toBe(true);
  });

  it('handles math nested back inside the text argument', () => {
    // `\text{if $x$ holds}` — still prose as far as trigger expansion goes.
    const doc = '$\\text{if x holds}$';
    expect(at(doc, doc.indexOf('holds'))).toBe(true);
  });

  it('recognises the \\text variants and \\mbox', () => {
    for (const cmd of ['textrm', 'textbf', 'textit', 'texttt', 'textnormal', 'mbox']) {
      const doc = `$\\${cmd}{ab}$`;
      expect(at(doc, doc.indexOf('ab') + 1), cmd).toBe(true);
    }
  });

  it('is not fooled by an escaped brace', () => {
    // `\{` is a literal brace, not a group opener.
    const doc = '$\\{ab\\}$';
    expect(at(doc, doc.indexOf('ab') + 1)).toBe(false);
  });

  it('is false for a non-text command with a braced argument', () => {
    const doc = '$\\frac{ab}{c}$';
    expect(at(doc, doc.indexOf('ab') + 1)).toBe(false);
  });

  it('reads the whole command name, and allows space before the brace', () => {
    expect(at('$\\text {ab}$', 9)).toBe(true);
    expect(at('$\\mytext{ab}$', 10)).toBe(false);
    expect(at('$\\textbfx{ab}$', 11)).toBe(false);
    expect(at('$x\\\\text{ab}$', 11)).toBe(true); // after a `\\` row break
  });
});

describe('snippet expansion inside \\text', () => {
  const snips = parseHSnips(
    `context math(context)\nsnippet nu "nu" Ai\n\\nu\nendsnippet\n` +
      `context !math(context)\nsnippet iff "iff" Ai\nif and only if\nendsnippet\n`,
  );
  // The composed predicate the hsnips engine gets, per setup.ts.
  const mathForSnippets = (state: EditorState, pos: number) =>
    isInMathContextTex(state, pos) && !isInLatexTextSpan(state, pos);

  const fires = (doc: string, pos: number) => {
    const state = EditorState.create({ doc, selection: EditorSelection.cursor(pos) });
    return _testing.findMatch(state, snips, mathForSnippets, true)?.snippet.body ?? null;
  };

  it('still expands a math snippet in real math', () => {
    expect(fires('$nu$', 3)).toBe('\\nu');
  });

  it('does not expand a math snippet inside \\text', () => {
    expect(fires('$\\text{number}$', 9)).toBeNull();
  });

  it('expands a prose snippet inside \\text, because that is prose', () => {
    // Caret right after "iff" and before the closing brace, at index 10.
    expect(fires('$\\text{iff}$', 10)).toBe('if and only if');
  });

  it('does not expand a prose snippet in real math', () => {
    expect(fires('$iff$', 4)).toBeNull();
  });
});
