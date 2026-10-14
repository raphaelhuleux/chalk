import { describe, it, expect, beforeAll, vi } from 'vitest';
import { EditorView } from '@codemirror/view';
import { EditorState, EditorSelection, Transaction } from '@codemirror/state';
import { parseHSnips, type HSnippet } from '../src/editor/hsnips-parser';
import { hsnipsExtension, setSnippets, _testing } from '../src/editor/hsnips-plugin';

const { findMatch } = _testing;

/**
 * Guard rails around snippet expansion:
 *  - the slow-regex circuit breaker (a catastrophically backtracking user
 *    pattern must not freeze the editor — audit H-2, measured 20.8s hang),
 *  - the Transaction.remote gate (host-sync updates must never expand
 *    snippets — audit M-18),
 *  - the exactly-one-char keystroke gate (paste must not auto-expand).
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

function makeView(doc: string, cursor: number, snippets: HSnippet[]): EditorView {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  const state = EditorState.create({
    doc,
    selection: EditorSelection.cursor(cursor),
    extensions: [hsnipsExtension({ isInMathContext: () => true })],
  });
  const view = new EditorView({ state, parent });
  view.dispatch({ effects: setSnippets.of(snippets) });
  return view;
}

/** Type one char at the end of the doc, like a keystroke. */
function typeChar(view: EditorView, ch: string): void {
  const pos = view.state.doc.length;
  view.dispatch({
    changes: { from: pos, to: pos, insert: ch },
    selection: EditorSelection.cursor(pos + 1),
    userEvent: 'input.type',
  });
}

const TE = 'snippet te "text" A\n\\text{$0}\nendsnippet\n';

describe('slow-regex circuit breaker', () => {
  it('disables a catastrophically backtracking snippet after its first slow exec', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    // (a+)+b against a run of a's (no b) backtracks in O(2^n): each typed
    // `a` doubles the exec cost, so some keystroke crosses the 100ms
    // threshold well before the seconds-long ones the breaker exists to
    // prevent.
    const parsed = parseHSnips('snippet `(a+)+b` "bomb" A\nBOOM\nendsnippet\n');
    expect(parsed[0].regexp).toBeDefined();
    const execSpy = vi.spyOn(parsed[0].regexp!, 'exec');
    const view = makeView('', 0, parsed);

    // Type a's until the breaker trips (bounded — must trip before 28).
    let typed = 0;
    const tripped = () =>
      warn.mock.calls.some((c) => String(c[0]).includes('(a+)+b'));
    while (typed < 28 && !tripped()) {
      typeChar(view, 'a');
      typed++;
    }
    expect(tripped()).toBe(true);
    const execsAtTrip = execSpy.mock.calls.length;

    // After tripping, the snippet is skipped entirely: further keystrokes
    // run zero execs and the doc updates normally (editor survives).
    typeChar(view, 'a');
    typeChar(view, 'a');
    typeChar(view, 'a');
    expect(execSpy.mock.calls.length).toBe(execsAtTrip);
    expect(view.state.doc.toString()).toBe('a'.repeat(typed + 3));

    view.destroy();
    warn.mockRestore();
  });
});

describe('Transaction.remote gate (host-sync updates)', () => {
  it('a remote-annotated change ending in an auto trigger does not expand', () => {
    const view = makeView('t', 1, parseHSnips(TE));
    view.dispatch({
      changes: { from: 1, to: 1, insert: 'e' },
      selection: EditorSelection.cursor(2),
      annotations: [
        Transaction.remote.of(true),
        Transaction.addToHistory.of(false),
      ],
    });
    expect(view.state.doc.toString()).toBe('te');
    view.destroy();
  });

  it('the same change without the annotation expands (control)', () => {
    const view = makeView('t', 1, parseHSnips(TE));
    view.dispatch({
      changes: { from: 1, to: 1, insert: 'e' },
      selection: EditorSelection.cursor(2),
    });
    expect(view.state.doc.toString()).toBe('\\text{}');
    view.destroy();
  });
});

describe('keystroke gate (exactly one inserted char)', () => {
  it('a multi-char insertion ending in an A-trigger does not expand (paste)', () => {
    const view = makeView('', 0, parseHSnips(TE));
    view.dispatch({
      changes: { from: 0, to: 0, insert: 'te' },
      selection: EditorSelection.cursor(2),
      userEvent: 'input.paste',
    });
    expect(view.state.doc.toString()).toBe('te');
    view.destroy();
  });

  it('typing the same chars one-by-one expands', () => {
    const view = makeView('', 0, parseHSnips(TE));
    typeChar(view, 't');
    typeChar(view, 'e');
    expect(view.state.doc.toString()).toBe('\\text{}');
    view.destroy();
  });
});

describe('empty-match regex guard', () => {
  // A user pattern with an all-optional tail (`[0-9]*`, `\d?`) matches the
  // empty string at the caret on any line. Without a guard that is a match
  // with from === to, so the body is inserted on EVERY keystroke.
  const QUANTIFIED = `
priority 10
snippet \`[0-9]*\` "optional digits" Ai
\\num{#1}
endsnippet
`;

  it('does not fire where the pattern matched nothing', () => {
    const state = EditorState.create({
      doc: 'hello',
      selection: EditorSelection.cursor(5),
    });
    expect(findMatch(state, parseHSnips(QUANTIFIED), () => true)).toBeNull();
  });

  it('still fires when the same pattern matches real text', () => {
    const state = EditorState.create({
      doc: 'a42',
      selection: EditorSelection.cursor(3),
    });
    const match = findMatch(state, parseHSnips(QUANTIFIED), () => true);
    expect(match).not.toBeNull();
    expect(match!.from).toBe(1);
    expect(match!.to).toBe(3);
  });
});

describe('the `b` flag (beginning of line)', () => {
  // UltiSnips/HyperSnips semantics: `b` expands the snippet when only
  // WHITESPACE precedes the trigger, not only at column 0. Requiring column 0
  // killed every `b` snippet typed inside an indented environment — an
  // `\item` body, a nested itemize — which is where they are most used.
  const LITERAL = 'snippet beq "block equation" bA\n\\begin{equation}\nendsnippet\n';
  const REGEX = 'snippet `eq(\\d)` "numbered equation" bA\nEQ#1\nendsnippet\n';

  function match(doc: string, source: string) {
    const state = EditorState.create({
      doc,
      selection: EditorSelection.cursor(doc.length),
    });
    return findMatch(state, parseHSnips(source), () => true);
  }

  it('expands a literal trigger indented inside an environment', () => {
    const m = match('    beq', LITERAL);
    expect(m).not.toBeNull();
    expect(m!.from).toBe(4);
    expect(m!.to).toBe(7);
  });

  it('still expands a literal trigger at column 0', () => {
    const m = match('beq', LITERAL);
    expect(m).not.toBeNull();
    expect(m!.from).toBe(0);
  });

  it('does not expand a literal trigger with real text before it', () => {
    expect(match('x beq', LITERAL)).toBeNull();
  });

  it('expands a regex trigger indented inside an environment', () => {
    const m = match('\t\teq7', REGEX);
    expect(m).not.toBeNull();
    expect(m!.from).toBe(2);
  });

  it('does not expand a regex trigger with real text before it', () => {
    expect(match('x eq7', REGEX)).toBeNull();
  });
});
