import { describe, it, expect } from 'vitest';
import { EditorState } from '@codemirror/state';
import { markdown } from '@codemirror/lang-markdown';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { mathSyntax } from '../src/editor/md-math-plugin';
import { highlightSyntax } from '../src/editor/md-highlight-plugin';

/**
 * Build a fully-parsed markdown state with the same extension set setup.ts
 * uses for the live-preview (math claims `$…$` before highlight sees `==`).
 */
function makeState(doc: string): EditorState {
  const state = EditorState.create({
    doc,
    extensions: [markdown({ extensions: [mathSyntax, highlightSyntax] })],
  });
  ensureSyntaxTree(state, state.doc.length, 5000);
  return state;
}

/** Ranges of every `Highlight` node in the parsed document. */
function highlights(doc: string): Array<{ from: number; to: number; text: string }> {
  const state = makeState(doc);
  const out: Array<{ from: number; to: number; text: string }> = [];
  syntaxTree(state).iterate({
    enter(node) {
      if (node.name === 'Highlight') {
        out.push({ from: node.from, to: node.to, text: doc.slice(node.from, node.to) });
      }
    },
  });
  return out;
}

describe('highlightSyntax parser', () => {
  it('recognizes ==text== as a Highlight node', () => {
    const hits = highlights('a ==marked== b');
    expect(hits).toHaveLength(1);
    expect(hits[0].text).toBe('==marked==');
  });

  it('emits two HighlightMark delimiter children', () => {
    const state = makeState('==x==');
    const marks: string[] = [];
    syntaxTree(state).iterate({
      enter(node) {
        if (node.name === 'HighlightMark') marks.push(state.doc.sliceString(node.from, node.to));
      },
    });
    expect(marks).toEqual(['==', '==']);
  });

  it('rejects empty ====', () => {
    expect(highlights('a ==== b')).toHaveLength(0);
  });

  it('rejects a longer === run (setext-ish)', () => {
    expect(highlights('a ===x=== b')).toHaveLength(0);
  });

  it('rejects an unclosed ==', () => {
    expect(highlights('a ==unterminated here')).toHaveLength(0);
  });

  it('does not span across a line break', () => {
    expect(highlights('a ==open\nclose== b')).toHaveLength(0);
  });

  it('ignores == inside an inline-math span', () => {
    // `$a == b$` is claimed by InlineMath first, so no Highlight is created.
    expect(highlights('compare $a == b$ here')).toHaveLength(0);
  });

  it('handles two separate highlights on one line', () => {
    const hits = highlights('==one== and ==two==');
    expect(hits.map((h) => h.text)).toEqual(['==one==', '==two==']);
  });
});
