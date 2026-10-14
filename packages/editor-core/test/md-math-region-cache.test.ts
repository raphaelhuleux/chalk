import { describe, it, expect } from 'vitest';
import { EditorState, Text } from '@codemirror/state';
import { markdown } from '@codemirror/lang-markdown';
import { syntaxTree } from '@codemirror/language';
import { mathSyntax, _testing } from '../src/editor/md-math-plugin';

const { mdMathRegions } = _testing;

/**
 * The md region list is asked for by two callers on hot paths: the
 * display-math field rebuilds with it, and the Up/Down keymap asks on every
 * press. Building it is a whole-tree iterate plus a slice and a regex per math
 * node, so it is memoized on (doc, tree) identity — the same shape as the tex
 * scanners' `WeakMap<Text, …>` caches, with the tree added because a
 * background parse can advance under an unchanged document.
 */

const DOC = [
  'Intro prose.',
  '',
  '$$',
  'E = mc^2',
  '$$',
  '',
  'More prose with $a+b$ inline.',
  '',
  '$$',
  '\\int_0^1 x\\,dx',
  '$$',
  '',
].join('\n');

function stateOf(doc: string | Text): EditorState {
  return EditorState.create({
    doc,
    extensions: [markdown({ extensions: [mathSyntax] })],
  });
}

describe('md display-math region cache', () => {
  it('returns the same array instance for repeated calls on one state', () => {
    const state = stateOf(DOC);
    const first = mdMathRegions(state);
    expect(first).toHaveLength(2);
    expect(mdMathRegions(state)).toBe(first);
    expect(mdMathRegions(state)).toBe(first);
  });

  it('rebuilds after a document change', () => {
    const state = stateOf(DOC);
    const before = mdMathRegions(state);
    const after = mdMathRegions(
      state.update({ changes: { from: 0, insert: 'Another paragraph.\n\n' } }).state,
    );
    expect(after).not.toBe(before);
    expect(after).toHaveLength(2);
    // Same blocks, shifted by the insert.
    expect(after[0].from).toBe(before[0].from + 20);
    expect(after[0].content).toBe(before[0].content);
  });

  it('rebuilds when the tree advances under an unchanged document', () => {
    // The same `Text` instance in two states: the doc half of the key hits,
    // so only the tree half can force the rescan.
    const doc = Text.of(DOC.split('\n'));
    const a = stateOf(doc);
    const b = stateOf(doc);
    expect(b.doc).toBe(a.doc);
    expect(syntaxTree(b)).not.toBe(syntaxTree(a));

    const first = mdMathRegions(a);
    const second = mdMathRegions(b);
    expect(second).not.toBe(first);
    expect(second.map((r) => [r.from, r.to, r.content])).toEqual(
      first.map((r) => [r.from, r.to, r.content]),
    );
  });
});
