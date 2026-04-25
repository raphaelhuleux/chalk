import { describe, it, expect } from 'vitest';
import { EditorState } from '@codemirror/state';
import { markdown } from '@codemirror/lang-markdown';
import { ensureSyntaxTree } from '@codemirror/language';
import { mathSyntax, isInMathContextMd } from '../../src/webview/editor/md-math-plugin';

/**
 * Builds an EditorState with the markdown parser + mathSyntax extension
 * and forces a full synchronous parse so `syntaxTree()` returns the
 * complete tree. The parser otherwise streams in chunks via background
 * work and queries against an unparsed range can return placeholder
 * nodes — that's safe in practice (the editor re-renders when the parse
 * completes) but breaks deterministic tests.
 */
function makeState(doc: string): EditorState {
  const state = EditorState.create({
    doc,
    extensions: [markdown({ extensions: [mathSyntax] })],
  });
  ensureSyntaxTree(state, state.doc.length, 5000);
  return state;
}

describe('isInMathContextMd', () => {
  it('returns true inside an inline math span', () => {
    const state = makeState('hello $x^2$ world');
    // Position 8 sits between the $-delimiters: 'hello $x^2$ world'
    //                                                   ^
    expect(isInMathContextMd(state, 8)).toBe(true);
  });

  it('returns false outside math', () => {
    const state = makeState('hello $x^2$ world');
    expect(isInMathContextMd(state, 1)).toBe(false);  // inside 'hello'
    expect(isInMathContextMd(state, 14)).toBe(false); // inside 'world'
  });

  it('returns true inside a display math block', () => {
    const state = makeState('text\n\n$$\nx^2\n$$\n\nmore');
    const idx = state.doc.toString().indexOf('x^2');
    expect(isInMathContextMd(state, idx + 1)).toBe(true);
  });

  it('returns false on a paragraph adjacent to display math', () => {
    const state = makeState('text\n\n$$\nx^2\n$$\n\nmore');
    const idx = state.doc.toString().indexOf('more');
    expect(isInMathContextMd(state, idx + 1)).toBe(false);
  });
});
