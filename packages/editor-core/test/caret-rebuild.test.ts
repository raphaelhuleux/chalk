import { describe, it, expect, beforeAll, afterEach } from 'vitest';
import { EditorView } from '@codemirror/view';
import { createEditorState } from '../src/editor/setup';
import {
  __concealBuildCount,
  __resetConcealBuildCount,
} from '../src/editor/tex-conceal-plugin';
import { __mathBuildCount, __resetMathBuildCount } from '../src/editor/tex-math';
import { moreWrappedRows } from '../src/editor/callout-core';
import { EditorSelection, EditorState, type Extension, type StateField } from '@codemirror/state';
import type { DecorationSet } from '@codemirror/view';
import { texListPlugin } from '../src/editor/tex-list-plugin';
import { texFramePlugin } from '../src/editor/tex-frame-plugin';
import { mathRegionsField } from '../src/editor/tex-math-incremental';
import { defaultEditorConfig } from '../src/editor/theme';
import { destroyViews, mdView } from './helpers/views';

/**
 * Caret-move rebuild guards. Both the conceal ViewPlugin and the math
 * StateField build WHOLE-DOCUMENT decoration sets (block/line-spanning
 * replaces force that), and both must rebuild when the caret crosses a
 * reveal boundary — but a caret move through plain prose changes nothing,
 * and used to rebuild both sets on every arrow key (the dominant caret-move
 * cost on large .tex documents).
 *
 * Boundary crossings still rebuild — that is asserted too, so the
 * short-circuit can never overreach into staleness.
 */

beforeAll(() => {
  if (typeof Range.prototype.getClientRects !== 'function') {
    Range.prototype.getClientRects = () => [] as unknown as DOMRectList;
  }
  if (typeof Range.prototype.getBoundingClientRect !== 'function') {
    Range.prototype.getBoundingClientRect = () =>
      ({ x: 0, y: 0, width: 0, height: 0, top: 0, right: 0, bottom: 0, left: 0, toJSON: () => ({}) }) as DOMRect;
  }
});

const DOC = [
  /*  1 */ '\\section{Introduction}',
  /*  2 */ 'plain prose line one with several words in it',
  /*  3 */ 'plain prose line two with several words in it',
  /*  4 */ 'Inline math $a+b=c$ sits mid text on this line.',
  /*  5 */ 'plain prose line three with several words in it',
  /*  6 */ '',
  /*  7 */ '$$',
  /*  8 */ 'x = y + z',
  /*  9 */ '$$',
  /* 10 */ '',
  /* 11 */ 'see \\ref{fig:model} and \\cite{smith2020} here',
  /* 12 */ 'plain prose line four with several words in it',
  /* 13 */ '\\begin{theorem}',
  /* 14 */ 'theorem body text sits here',
  /* 15 */ '\\end{theorem}',
  /* 16 */ 'buffer line below the theorem block',
  /* 17 */ 'final prose line with several words in it',
].join('\n');

function makeTexView(): EditorView {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  const state = createEditorState(DOC, { onContentChange: () => {} }, 'tex');
  return new EditorView({ state, parent });
}

/** Offsets inside plain-prose lines, far from math, pills, and fences. */
function proseOffsets(view: EditorView): number[] {
  const doc = view.state.doc;
  return [2, 3, 5, 17].flatMap((n) => {
    const line = doc.line(n);
    return [line.from + 3, line.from + 12, line.to - 2];
  });
}

describe('caret moves through plain prose', () => {
  it('never rebuild the conceal decorations', () => {
    const view = makeTexView();
    const offsets = proseOffsets(view);
    // Park in prose first: the fresh view's caret sits at 0, INSIDE the
    // \section command, so the first move out is a real reveal change.
    view.dispatch({ selection: { anchor: offsets[0] } });
    __resetConcealBuildCount();
    for (const pos of offsets) view.dispatch({ selection: { anchor: pos } });
    expect(__concealBuildCount()).toBe(0);
    view.destroy();
  });

  it('never rebuild the math decorations', () => {
    const view = makeTexView();
    const offsets = proseOffsets(view);
    view.dispatch({ selection: { anchor: offsets[0] } });
    __resetMathBuildCount();
    for (const pos of offsets) view.dispatch({ selection: { anchor: pos } });
    expect(__mathBuildCount()).toBe(0);
    view.destroy();
  });
});

describe('moreWrappedRows measures once per key event', () => {
  // Three keymap handlers (fence stop, list fence, display-math entry) call
  // moreWrappedRows with identical arguments inside ONE keydown; each call
  // did a coordsAtPos + moveVertically forced geometry measurement. The memo
  // must collapse them, and must NOT survive the event turn (microtask
  // lifetime) or a dispatch (state identity).
  it('collapses same-turn repeat calls, recomputes after microtask/dispatch/dir change', async () => {
    const view = makeTexView();
    let coordsCalls = 0;
    let moveCalls = 0;
    (view as unknown as { coordsAtPos: unknown }).coordsAtPos = () => {
      coordsCalls++;
      return { left: 0, right: 1, top: 0, bottom: 10 };
    };
    (view as unknown as { moveVertically: unknown }).moveVertically = () => {
      moveCalls++;
      return EditorSelection.cursor(view.state.selection.main.head + 1);
    };

    expect(moreWrappedRows(view, 1)).toBe(true); // same doc line → wrapped row
    expect(moreWrappedRows(view, 1)).toBe(true); // keymap sibling, same turn
    expect(moreWrappedRows(view, 1)).toBe(true); // third sibling
    expect(coordsCalls).toBe(1);
    expect(moveCalls).toBe(1);

    moreWrappedRows(view, -1); // direction is part of the key
    expect(coordsCalls).toBe(2);

    await Promise.resolve(); // next event turn
    moreWrappedRows(view, 1);
    expect(coordsCalls).toBe(3);

    view.dispatch({ selection: { anchor: view.state.doc.line(3).from } });
    moreWrappedRows(view, 1); // new state identity → recompute
    expect(coordsCalls).toBe(4);
    view.destroy();
  });
});

describe('display math sharing a line with inline math still rebuilds', () => {
  // A display region's reveal is LINE-based: it must flip from any caret
  // position on a line the region touches. The old nearMathRegion candidate
  // window (binary-search hit ±1) missed a display region separated from the
  // caret by other math regions on the same document line, so the
  // selection-only skip kept a stale set.
  const SHARED_DOC = [
    /* 1 */ 'plain prose line one with several words in it',
    /* 2 */ 'plain prose line two with several words in it',
    /* 3 */ 'Since $r$ is fixed \\[ y = X\\beta + u \\]',
    /* 4 */ 'plain prose line three with several words in it',
    /* 5 */ 'The model is \\[ y = X\\beta \\] where $y$ is outcome and $X$ regressors',
    /* 6 */ 'plain prose line four with several words in it',
  ].join('\n');

  function makeSharedView(): EditorView {
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const state = createEditorState(SHARED_DOC, { onContentChange: () => {} }, 'tex');
    return new EditorView({ state, parent });
  }

  it('rebuilds when the caret lands at column 0 with an inline region before a mid-line display', () => {
    const view = makeSharedView();
    const prose = view.state.doc.line(2).from + 3;
    view.dispatch({ selection: { anchor: prose } });
    __resetMathBuildCount();
    // Column 0 of line 3: the caret is left of `$r$`, but the display
    // `\[…\]` shares the line, so its source must reveal.
    view.dispatch({ selection: { anchor: view.state.doc.line(3).from }, userEvent: 'select' });
    expect(__mathBuildCount()).toBe(1);
    view.destroy();
  });

  it('rebuilds on ArrowDown out of a tail caret behind a display plus two inline regions', () => {
    const view = makeSharedView();
    const doc = view.state.doc;
    // Park inside the display region (source revealed), then move to the
    // tail text after `$X$` — still on line 5, reveal must persist.
    const inDisplay = doc.line(5).from + doc.line(5).text.indexOf('X\\beta') + 1;
    view.dispatch({ selection: { anchor: inDisplay } });
    const tail = doc.line(5).to - 3; // inside "regressors", after $y$ and $X$
    view.dispatch({ selection: { anchor: tail }, userEvent: 'select' });
    __resetMathBuildCount();
    // ArrowDown to line 6: leaving the line must collapse the display reveal.
    view.dispatch({ selection: { anchor: doc.line(6).from + 3 }, userEvent: 'select' });
    expect(__mathBuildCount()).toBe(1);
    view.destroy();
  });
});

describe('caret moves across reveal boundaries still rebuild', () => {
  it('conceal rebuilds when the caret enters and leaves a ref pill', () => {
    const view = makeTexView();
    const doc = view.state.doc.toString();
    const inRef = doc.indexOf('fig:model') + 2;
    const prose = view.state.doc.line(2).from + 3;
    view.dispatch({ selection: { anchor: prose } });
    __resetConcealBuildCount();
    view.dispatch({ selection: { anchor: inRef } }); // prose → inside \ref
    expect(__concealBuildCount()).toBe(1);
    view.dispatch({ selection: { anchor: prose } }); // back out
    expect(__concealBuildCount()).toBe(2);
    view.destroy();
  });

  it('math resyncs on keyboard motion after a pointer-frozen stale set', () => {
    // Caret in the display block (source revealed) → pointer-select to prose
    // (gesture-freeze keeps the reveal on screen, set now STALE) → keyboard
    // move prose→prose. The keyboard move must rebuild even though neither
    // position is near math: the current set does not match the state.
    const view = makeTexView();
    const eqBody = view.state.doc.line(8).from + 2;
    const prose = view.state.doc.line(2).from + 3;
    view.dispatch({ selection: { anchor: eqBody } }); // revealed
    view.dispatch({ selection: { anchor: prose }, userEvent: 'select.pointer' }); // frozen
    __resetMathBuildCount();
    view.dispatch({ selection: { anchor: prose + 1 } }); // keyboard
    expect(__mathBuildCount()).toBe(1);
    view.destroy();
  });

  it('math rebuilds when the caret enters a display block, and on typing', () => {
    const view = makeTexView();
    const eqBody = view.state.doc.line(8).from + 2; // inside x = y + z
    const prose = view.state.doc.line(2).from + 3;
    view.dispatch({ selection: { anchor: prose } });
    __resetMathBuildCount();
    view.dispatch({ selection: { anchor: eqBody } });
    expect(__mathBuildCount()).toBeGreaterThanOrEqual(1);
    const before = __mathBuildCount();
    view.dispatch({ selection: { anchor: prose } });
    const pos = view.state.selection.main.head;
    view.dispatch({ changes: { from: pos, insert: 'x' }, selection: { anchor: pos + 1 } });
    expect(__mathBuildCount()).toBeGreaterThan(before); // doc changes always rebuild
    view.destroy();
  });
});

describe('md display math skips selection-only rebuilds far from math', () => {
  afterEach(destroyViews);

  const MD_DOC = [
    /*  1 */ '# Heading',
    /*  2 */ 'plain prose line one with several words in it',
    /*  3 */ 'plain prose line two with $$ a+b $$ display math in it',
    /*  4 */ 'plain prose line three with several words in it',
    /*  5 */ '',
    /*  6 */ '$$',
    /*  7 */ 'x = y + z',
    /*  8 */ '$$',
    /*  9 */ '',
    /* 10 */ '::: {#thm-a}',
    /* 11 */ '$$',
    /* 12 */ 'e = mc^2',
    /* 13 */ '$$',
    /* 14 */ ':::',
    /* 15 */ '',
    /* 16 */ 'final prose line with several words in it',
    /* 17 */ 'another prose line with several words in it',
  ].join('\n');

  const at = (view: EditorView, line: number, col = 3) => view.state.doc.line(line).from + col;

  it('never rebuilds on caret moves through prose', () => {
    const view = mdView(MD_DOC, { ensureTree: true });
    view.dispatch({ selection: { anchor: at(view, 2) } });
    __resetMathBuildCount();
    for (const [line, col] of [[2, 10], [4, 3], [4, 20], [16, 5], [17, 5], [2, 1]]) {
      view.dispatch({ selection: { anchor: at(view, line, col) } });
    }
    expect(__mathBuildCount()).toBe(0);
  });

  it('rebuilds entering and leaving a block, and paragraph-interior $$…$$', () => {
    const view = mdView(MD_DOC, { ensureTree: true });
    view.dispatch({ selection: { anchor: at(view, 2) } });
    __resetMathBuildCount();
    view.dispatch({ selection: { anchor: at(view, 7) } });
    expect(__mathBuildCount()).toBe(1);
    view.dispatch({ selection: { anchor: at(view, 4) } });
    expect(__mathBuildCount()).toBe(2);
    // Its reveal is char-based: the same line outside it keeps the set.
    view.dispatch({ selection: { anchor: at(view, 3) } });
    expect(__mathBuildCount()).toBe(2);
    const inside = view.state.doc.line(3).from + view.state.doc.line(3).text.indexOf('a+b');
    view.dispatch({ selection: { anchor: inside } });
    expect(__mathBuildCount()).toBe(3);
  });

  it('rebuilds when the caret reaches the callout close fence under a block', () => {
    const view = mdView(MD_DOC, { ensureTree: true });
    view.dispatch({ selection: { anchor: at(view, 17) } });
    __resetMathBuildCount();
    // The fence's collapse decides whether the block above carries the box
    // bottom (calloutBlockAt).
    view.dispatch({ selection: { anchor: at(view, 14, 0) } });
    expect(__mathBuildCount()).toBe(1);
  });
});

describe('list and frame fields keep their set when the selection cannot matter', () => {
  const LIST_DOC = [
    'prose before the list with words',
    '\\begin{itemize}',
    '\\item first item text',
    '\\item second item text',
    '\\end{itemize}',
    'prose after the list with words',
  ].join('\n');
  const FRAME_DOC = [
    '\\documentclass{beamer}',
    'preamble prose line',
    '',
    '\\begin{frame}{Title}',
    '  body line',
    '\\end{frame}',
    'trailing prose line',
  ].join('\n');

  /** A bare state carrying one plugin's field, and a reader for its set. */
  function withField(doc: string, ext: Extension) {
    const field = (ext as StateField<DecorationSet>[])[0];
    let state = EditorState.create({ doc, extensions: [mathRegionsField, ext] });
    return {
      move(anchor: number): DecorationSet {
        const before = state.field(field);
        state = state.update({ selection: { anchor } }).state;
        return before;
      },
      get set(): DecorationSet {
        return state.field(field);
      },
      line: (n: number) => state.doc.line(n),
    };
  }

  it('Preview list: prose and item-text moves keep the set, an \\item token rebuilds', () => {
    const f = withField(LIST_DOC, texListPlugin());
    f.move(3);
    expect(f.move(f.line(6).from + 4)).toBe(f.set);
    expect(f.move(f.line(3).to - 2)).toBe(f.set); // item text, past the token
    const before = f.move(f.line(4).from + 2); // inside `\item`
    expect(f.set).not.toBe(before);
    const again = f.move(f.line(5).from + 2); // onto the close fence
    expect(f.set).not.toBe(again);
  });

  it('Mixed list: no selection move rebuilds', () => {
    const f = withField(LIST_DOC, texListPlugin({ conceal: false }));
    for (const n of [1, 2, 3, 5, 6]) expect(f.move(f.line(n).from + 2)).toBe(f.set);
  });

  it('Preview frame: moves outside every frame keep the set, entering one rebuilds', () => {
    const f = withField(FRAME_DOC, texFramePlugin());
    f.move(f.line(7).from + 2);
    expect(f.move(f.line(7).to)).toBe(f.set);
    const before = f.move(f.line(4).from + 2);
    expect(f.set).not.toBe(before);
  });

  it('Mixed frame: no selection move rebuilds', () => {
    const f = withField(FRAME_DOC, texFramePlugin({ conceal: false }));
    for (const n of [2, 4, 5, 6, 7]) expect(f.move(f.line(n).from + 2)).toBe(f.set);
  });

  it('Mixed conceal: entering a command never rebuilds', () => {
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const state = createEditorState(DOC, { onContentChange: () => {} }, 'tex', {
      config: { ...defaultEditorConfig, viewMode: 'mixed' },
    });
    const view = new EditorView({ state, parent });
    const doc = view.state.doc.toString();
    view.dispatch({ selection: { anchor: view.state.doc.line(2).from + 3 } });
    __resetConcealBuildCount();
    view.dispatch({ selection: { anchor: doc.indexOf('fig:model') + 2 } });
    view.dispatch({ selection: { anchor: doc.indexOf('Introduction') } });
    expect(__concealBuildCount()).toBe(0);
    view.destroy();
  });
});
