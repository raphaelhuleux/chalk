import { describe, it, expect } from 'vitest';
import { EditorState } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { markdown } from '@codemirror/lang-markdown';
import { Strikethrough, Table, TaskList } from '@lezer/markdown';
import { ensureSyntaxTree } from '@codemirror/language';
import { buildLivePreviewDecorations } from '../src/editor/md-live-preview';
import { frontmatterSyntax } from '../src/editor/md-frontmatter';
import { mathSyntax } from '../src/editor/md-math-plugin';
import { highlightSyntax } from '../src/editor/md-highlight-plugin';

/**
 * A block widget (a `$$…$$` display block, a callout fence, a table) hides its
 * range from the viewport, so `view.visibleRanges` arrives as several disjoint
 * ranges. Any syntax node that STRADDLES such a gap — a blockquote holding a
 * display block, say — is entered once per range, so a naive per-range
 * iteration re-adds the node's own decoration after already having added its
 * children's. `RangeSetBuilder` then throws "Ranges must be added sorted by
 * `from` position and `startSide`", CM6 disables the whole plugin, and the
 * document loses every heading, image, link and bold run at once.
 */
function stateFor(doc: string): EditorState {
  const state = EditorState.create({
    doc,
    extensions: [
      markdown({
        extensions: [frontmatterSyntax, mathSyntax, highlightSyntax, Strikethrough, TaskList, Table],
      }),
    ],
  });
  ensureSyntaxTree(state, doc.length, 5000);
  return state;
}

/** The two things `buildLivePreviewDecorations` reads off the view. */
function fakeView(state: EditorState, visibleRanges: readonly { from: number; to: number }[]): EditorView {
  return { state, visibleRanges } as unknown as EditorView;
}

const QUOTE_WITH_DISPLAY_BLOCK = [
  '# Heading {#sec-one}',
  '',
  '> A blockquote with inline math and a display block:',
  '>',
  '> $$',
  '> \\langle Py,\\, My \\rangle = 0 .',
  '> $$',
  '>',
  '> The quote bar should run the full height of both.',
  '',
  '![fig](figures/plot.png)',
  '',
].join('\n');

describe('live preview across viewport gaps', () => {
  it('does not throw when a blockquote straddles a gap in visibleRanges', () => {
    const state = stateFor(QUOTE_WITH_DISPLAY_BLOCK);
    const displayFrom = state.doc.line(5).from; // "> $$"
    const displayTo = state.doc.line(7).to; // closing "> $$"

    expect(() =>
      buildLivePreviewDecorations(
        fakeView(state, [
          { from: 0, to: displayFrom },
          { from: displayTo, to: state.doc.length },
        ]),
      ),
    ).not.toThrow();
  });

  it('still decorates the heading and image on either side of the gap', () => {
    const state = stateFor(QUOTE_WITH_DISPLAY_BLOCK);
    const displayFrom = state.doc.line(5).from;
    const displayTo = state.doc.line(7).to;
    const set = buildLivePreviewDecorations(
      fakeView(state, [
        { from: 0, to: displayFrom },
        { from: displayTo, to: state.doc.length },
      ]),
    );

    const classes: string[] = [];
    const widgets: string[] = [];
    set.between(0, state.doc.length, (_f, _t, value) => {
      const spec = value.spec as { class?: string; widget?: { constructor: { name: string } } };
      if (spec.class) classes.push(spec.class);
      if (spec.widget) widgets.push(spec.widget.constructor.name);
    });

    expect(classes).toContain('cm-h1');
    expect(classes).toContain('cm-live-blockquote');
    expect(widgets).toContain('ImageWidget');
  });

  it('emits each straddling node exactly once', () => {
    const state = stateFor(QUOTE_WITH_DISPLAY_BLOCK);
    const displayFrom = state.doc.line(5).from;
    const displayTo = state.doc.line(7).to;
    const set = buildLivePreviewDecorations(
      fakeView(state, [
        { from: 0, to: displayFrom },
        { from: displayTo, to: state.doc.length },
      ]),
    );

    let blockquotes = 0;
    set.between(0, state.doc.length, (_f, _t, value) => {
      if ((value.spec as { class?: string }).class === 'cm-live-blockquote') blockquotes += 1;
    });
    expect(blockquotes).toBe(1);
  });
});
