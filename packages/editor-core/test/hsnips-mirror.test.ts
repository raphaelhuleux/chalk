import { describe, it, expect, beforeAll } from 'vitest';
import { EditorView } from '@codemirror/view';
import { EditorState, EditorSelection, Transaction } from '@codemirror/state';
import { _testing, hsnipsExtension, hsnipsKeymap, insertSnippetBody } from '../src/editor/hsnips-plugin';

const { processBody, uniqueIndices, sessionField, setSession, mirrorFilter } =
  _testing;

beforeAll(() => {
  if (typeof Range.prototype.getClientRects !== 'function') {
    Range.prototype.getClientRects = () => [] as unknown as DOMRectList;
  }
  if (typeof Range.prototype.getBoundingClientRect !== 'function') {
    Range.prototype.getBoundingClientRect = () =>
      ({ x: 0, y: 0, width: 0, height: 0, top: 0, right: 0, bottom: 0, left: 0, toJSON: () => ({}) }) as DOMRect;
  }
});

describe('processBody — mirror groups', () => {
  it('emits two tab-stops for `\\frac{$1}{$1}`', () => {
    const { text, tabStops } = processBody('\\frac{$1}{$1}', 0, []);
    expect(text).toBe('\\frac{}{}');
    expect(tabStops.length).toBe(2);
    // Both indices are 1. Leader (first in array) is the earlier `from`.
    expect(tabStops[0].index).toBe(1);
    expect(tabStops[1].index).toBe(1);
    expect(tabStops[0].from).toBeLessThan(tabStops[1].from);
  });

  it('keeps the leader stable across $1/$0 sort (1 before 0)', () => {
    const { tabStops } = processBody('a$1 b$0 c$1', 0, []);
    expect(uniqueIndices(tabStops)).toEqual([1, 0]);
  });

  it('preserves document order for same-index stops after sort', () => {
    const { tabStops } = processBody('${1:x} y ${1:z}', 0, []);
    // Default texts mean the two `$1` stops have distinct ranges.
    expect(tabStops.length).toBe(2);
    expect(tabStops.every((s) => s.index === 1)).toBe(true);
    expect(tabStops[0].from).toBeLessThan(tabStops[1].from);
  });

  it('matches nested braces in a `${N:default}` default value', () => {
    // The `}` inside `\frac{a}{b}` must NOT close the placeholder early.
    const { text, tabStops } = processBody('${1:\\frac{a}{b}}', 0, []);
    expect(text).toBe('\\frac{a}{b}');
    expect(tabStops.length).toBe(1);
    expect(tabStops[0].index).toBe(1);
    expect(tabStops[0].from).toBe(0);
    expect(tabStops[0].to).toBe('\\frac{a}{b}'.length);
  });

  it('continues parsing body text after a braced default', () => {
    const { text, tabStops } = processBody('${1:\\frac{a}{b}}=$2', 0, []);
    expect(text).toBe('\\frac{a}{b}=');
    expect(tabStops.map((s) => s.index)).toEqual([1, 2]);
    // The `$2` lands right after the inserted `=`, proving the scan resumed
    // past the matching close brace (not the first inner `}`).
    expect(tabStops[1].from).toBe('\\frac{a}{b}='.length);
  });
});

describe('mirrorFilter — echoes leader edits to siblings', () => {
  function makeMirrorView(doc: string, leaderRange: [number, number], mirrorRange: [number, number]) {
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const state = EditorState.create({
      doc,
      selection: EditorSelection.cursor(leaderRange[1]),
      extensions: [sessionField, mirrorFilter],
    });
    const view = new EditorView({ state, parent });
    view.dispatch({
      effects: setSession.of({
        tabStops: [
          { from: leaderRange[0], to: leaderRange[1], index: 1 },
          { from: mirrorRange[0], to: mirrorRange[1], index: 1 },
        ],
        currentIndex: 1,
      }),
    });
    return view;
  }

  it('typing a character at the leader range echoes to the mirror', () => {
    // doc: \frac{}{}   leader at [6,6], mirror at [8,8]
    const view = makeMirrorView('\\frac{}{}', [6, 6], [8, 8]);
    view.dispatch({
      changes: { from: 6, to: 6, insert: 'a' },
      selection: EditorSelection.cursor(7),
    });
    // Leader gets 'a', then mirror also gets 'a' → '\frac{a}{a}'
    expect(view.state.doc.toString()).toBe('\\frac{a}{a}');
    view.destroy();
  });

  it('replacing leader content with a multi-char string mirrors fully', () => {
    // doc: \frac{x}{x}, leader[6,7]='x' first, mirror[10,11]='x' second
    // Note: the leader is the FIRST occurrence by document order.
    const view = makeMirrorView('\\frac{x}{x}', [6, 7], [9, 10]);
    view.dispatch({
      changes: { from: 6, to: 7, insert: 'pi' },
    });
    expect(view.state.doc.toString()).toBe('\\frac{pi}{pi}');
    view.destroy();
  });

  it('edits outside the leader range do not echo', () => {
    const view = makeMirrorView('xx\\frac{a}{a}', [8, 9], [11, 12]);
    view.dispatch({ changes: { from: 0, to: 0, insert: 'y' } });
    // Only the prefix gained 'y'; mirrors untouched.
    expect(view.state.doc.toString()).toBe('yxx\\frac{a}{a}');
    view.destroy();
  });

  // Host-sync updates are tagged Transaction.remote by mount.ts; even when
  // their diff lands inside the active leader they must not be echoed into
  // the mirrors (the remote text is authoritative — audit M-18).
  it('a remote-annotated change intersecting the leader does not overwrite mirrors', () => {
    const view = makeMirrorView('\\frac{}{}', [6, 6], [8, 8]);
    view.dispatch({
      changes: { from: 6, to: 6, insert: 'a' },
      annotations: [
        Transaction.remote.of(true),
        Transaction.addToHistory.of(false),
      ],
    });
    // Leader position got the synced 'a'; the mirror stayed empty.
    expect(view.state.doc.toString()).toBe('\\frac{a}{}');
    view.destroy();
  });
});

describe('tab-stop ranges grow with what is typed into them', () => {
  function sessionView(body: string): EditorView {
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const view = new EditorView({
      state: EditorState.create({ extensions: [hsnipsExtension({ isInMathContext: () => false })] }),
      parent,
    });
    insertSnippetBody(view, 0, 0, body);
    return view;
  }
  const type = (view: EditorView, text: string) => {
    for (const ch of text) {
      const p = view.state.selection.main.head;
      view.dispatch({
        changes: { from: p, insert: ch },
        selection: EditorSelection.cursor(p + 1),
        userEvent: 'input.type',
      });
    }
  };
  const backspace = (view: EditorView) => {
    const p = view.state.selection.main.head;
    view.dispatch({
      changes: { from: p - 1, to: p },
      selection: EditorSelection.cursor(p - 1),
      userEvent: 'delete.backward',
    });
  };
  const tab = (view: EditorView) => hsnipsKeymap.find((k) => k.key === 'Tab')!.run!(view);

  it('an empty stop covers the text typed into it', () => {
    const view = sessionView('\\textbf{$1}$0');
    type(view, 'ab');
    const stops = view.state.field(sessionField)!.tabStops;
    expect(view.state.sliceDoc(stops[0].from, stops[0].to)).toBe('ab');
    view.destroy();
  });

  it('Backspace in the leader is mirrored', () => {
    const view = sessionView('\\begin{$1}\n$0\n\\end{$1}');
    type(view, 'itemize');
    backspace(view);
    backspace(view);
    expect(view.state.doc.toString()).toBe('\\begin{itemi}\n\n\\end{itemi}');
    view.destroy();
  });

  it('an edit in the middle of the leader is mirrored', () => {
    const view = sessionView('\\begin{$1}\n$0\n\\end{$1}');
    type(view, 'itemize');
    view.dispatch({ selection: EditorSelection.cursor(view.state.selection.main.head - 2) });
    type(view, 'X');
    expect(view.state.doc.toString()).toBe('\\begin{itemiXze}\n\n\\end{itemiXze}');
    view.destroy();
  });

  it('adjacent stops `$1$2` keep their own text', () => {
    const view = sessionView('$1$2$0');
    type(view, 'a');
    tab(view);
    expect(view.state.selection.main).toMatchObject({ from: 1, to: 1 });
    type(view, 'b');
    const stops = view.state.field(sessionField)!.tabStops;
    expect(stops.map((s) => view.state.sliceDoc(s.from, s.to))).toEqual(['a', 'b', '']);
    view.destroy();
  });

  it('adjacent stops with defaults `${1:x}${2:y}` keep their own text', () => {
    const view = sessionView('${1:x}${2:y}$0');
    type(view, 'a'); // replaces the selected `x`
    tab(view);
    expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe('y');
    view.destroy();
  });
});
