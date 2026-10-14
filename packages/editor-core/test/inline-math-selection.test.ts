import { describe, it, expect, beforeAll } from 'vitest';
import { EditorView } from '@codemirror/view';
import { EditorState, EditorSelection } from '@codemirror/state';
import { selectCharLeft, selectCharRight } from '@codemirror/commands';
import { StreamLanguage, ensureSyntaxTree } from '@codemirror/language';
import { stex } from '@codemirror/legacy-modes/mode/stex';
import { markdown } from '@codemirror/lang-markdown';
import { texMathPlugin } from '../src/editor/tex-math';
import { mathPlugin, mathSyntax } from '../src/editor/md-math-plugin';

/**
 * Selecting inside inline math used to collapse the raw source back into the
 * rendered KaTeX widget the moment the selection became non-empty. A replace
 * widget has no DOM position inside it, so CM6 resolved both selection ends to
 * the widget's outer edge: the caret jumped past the closing `$` and the next
 * keystroke was inserted AFTER the formula instead of replacing the selection.
 *
 * The source must stay revealed while the whole selection lives inside the
 * region. A selection that crosses the boundary still renders — that is what
 * keeps a drag from reflowing text out from under the highlight.
 */

// jsdom has no layout; CM6's measure pass calls these on view creation.
beforeAll(() => {
  if (typeof Range.prototype.getClientRects !== 'function') {
    Range.prototype.getClientRects = () => [] as unknown as DOMRectList;
  }
  if (typeof Range.prototype.getBoundingClientRect !== 'function') {
    Range.prototype.getBoundingClientRect = () =>
      ({ x: 0, y: 0, width: 0, height: 0, top: 0, right: 0, bottom: 0, left: 0,
         toJSON: () => ({}) }) as DOMRect;
  }
});

function makeTexView(doc: string, cursor: number): EditorView {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  const state = EditorState.create({
    doc,
    selection: EditorSelection.cursor(cursor),
    extensions: [StreamLanguage.define(stex), texMathPlugin()],
  });
  return new EditorView({ state, parent });
}

function makeMdView(doc: string, cursor: number): EditorView {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  const state = EditorState.create({
    doc,
    selection: EditorSelection.cursor(cursor),
    extensions: [markdown({ extensions: [mathSyntax] }), mathPlugin()],
  });
  ensureSyntaxTree(state, state.doc.length, 5000);
  return new EditorView({ state, parent });
}

/** The rendered widget is present ⇒ the source is concealed. */
const texRendered = (v: EditorView) => v.dom.querySelector('.cm-tex-math-inline') !== null;
const mdRendered = (v: EditorView) => v.dom.querySelector('.cm-math-inline') !== null;

// 'Consider $E_{z}$ here' — opening $ at 9, closing $ at 15, region [9, 16)
const DOC = 'Consider $E_{z}$ here';
const OPEN = 9;
const CLOSE = 15;

describe('tex inline math keeps its source while a selection sits inside it', () => {
  it('Shift+Left from before the closing $ does not re-render the formula', () => {
    const view = makeTexView(DOC, CLOSE);
    expect(texRendered(view)).toBe(false); // caret inside: revealed
    selectCharLeft(view);
    expect(view.state.selection.main.head).toBe(CLOSE - 1);
    expect(view.state.selection.main.empty).toBe(false);
    expect(texRendered(view)).toBe(false);
    view.destroy();
  });

  it('Shift+Right from just inside the opening $ does not re-render it', () => {
    const view = makeTexView(DOC, OPEN + 1);
    selectCharRight(view);
    expect(texRendered(view)).toBe(false);
    view.destroy();
  });

  it('renders again once the selection crosses out of the region', () => {
    // Anchor inside, head dragged past the opening $ — no longer contained.
    const view = makeTexView(DOC, CLOSE);
    view.dispatch({ selection: EditorSelection.range(CLOSE, OPEN - 1) });
    expect(texRendered(view)).toBe(true);
    view.destroy();
  });

  it('stays rendered when the selection covers the whole formula', () => {
    // What a drag across the rendered formula produces: while it is rendered,
    // coordinates resolve only to its two edges. Both ends are outside the
    // widget, so it must not flash open mid-drag.
    const view = makeTexView(DOC, CLOSE + 1);
    view.dispatch({ selection: EditorSelection.range(OPEN, CLOSE + 1) });
    expect(texRendered(view)).toBe(true);
    view.destroy();
  });
});

describe('md inline math keeps its source while a selection sits inside it', () => {
  it('Shift+Left from before the closing $ does not re-render the formula', () => {
    const view = makeMdView(DOC, CLOSE);
    expect(mdRendered(view)).toBe(false);
    selectCharLeft(view);
    expect(view.state.selection.main.head).toBe(CLOSE - 1);
    expect(mdRendered(view)).toBe(false);
    view.destroy();
  });

  it('renders again once the selection crosses out of the region', () => {
    const view = makeMdView(DOC, CLOSE);
    view.dispatch({ selection: EditorSelection.range(CLOSE, OPEN - 1) });
    expect(mdRendered(view)).toBe(true);
    view.destroy();
  });

  it('stays rendered when the selection covers the whole formula', () => {
    const view = makeMdView(DOC, CLOSE + 1);
    view.dispatch({ selection: EditorSelection.range(OPEN, CLOSE + 1) });
    expect(mdRendered(view)).toBe(true);
    view.destroy();
  });
});
