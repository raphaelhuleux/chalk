import { describe, it, expect, afterEach } from 'vitest';
import { Prec, StateEffect } from '@codemirror/state';
import { EditorView, keymap } from '@codemirror/view';
import { snapVerticalLanding } from '../src/editor/tex-vertical-motion';
import { scanMathRegions } from '../src/editor/tex-math';
import { destroyViews, texView } from './helpers/views';

// ---------------------------------------------------------------------------
// Vertical caret motion over concealed constructs.
//
// Up/Down transit must never land the caret INSIDE a widget-rendered region
// (inline math, ref/cite/label/footnote pills) — landing there reveals the
// construct, reflows the line under the motion, and the caret "jumps".
// Landings snap to the nearest edge instead; the construct stays rendered.
// Landing on the VISIBLE argument text of \emph/\textbf/headings stays
// allowed (those are real letters), but a landing inside their HIDDEN
// \command{ prefix snaps forward to the first visible character.
// ---------------------------------------------------------------------------

const mountState = (docText: string) => texView(docText).state;

afterEach(destroyViews);

describe('snapVerticalLanding', () => {
  it('snaps a landing inside inline math to the nearest edge', () => {
    const doc = 'aa $x+y$ bb';
    const state = mountState(doc);
    const from = doc.indexOf('$');
    const to = doc.lastIndexOf('$') + 1; // one past closing delimiter
    // Just inside the opening delimiter → left edge (before the $).
    expect(snapVerticalLanding(state, from + 1)).toBe(from - 1);
    // Near the close → right edge (just past the $, concealed side).
    expect(snapVerticalLanding(state, to - 1)).toBe(to);
    // AT the opening delimiter also reveals → still snaps.
    expect(snapVerticalLanding(state, from)).toBe(from - 1);
    // At the exclusive end: outside, no snap.
    expect(snapVerticalLanding(state, to)).toBeNull();
  });

  it('snaps out of a ref pill to the nearest side', () => {
    const doc = 'see \\ref{fig:model} here';
    const state = mountState(doc);
    const cmdFrom = doc.indexOf('\\ref');
    const end = doc.indexOf('}') + 1;
    expect(snapVerticalLanding(state, cmdFrom + 1)).toBe(cmdFrom - 1);
    expect(snapVerticalLanding(state, end - 1)).toBe(end);
  });

  it('snaps a landing in a hidden \\emph{ prefix to the first visible letter', () => {
    const doc = 'aa \\emph{word} bb';
    const state = mountState(doc);
    const cmdFrom = doc.indexOf('\\emph');
    const argFrom = doc.indexOf('word');
    expect(snapVerticalLanding(state, cmdFrom + 2)).toBe(argFrom);
  });

  it('leaves landings on visible argument text alone', () => {
    const doc = 'aa \\emph{word} bb';
    const state = mountState(doc);
    expect(snapVerticalLanding(state, doc.indexOf('word') + 2)).toBeNull();
  });

  it('leaves plain text and display math alone', () => {
    const doc = 'plain text\n\\[a+b\\]\nmore';
    const state = mountState(doc);
    expect(snapVerticalLanding(state, 2)).toBeNull();
    const inside = doc.indexOf('a+b') + 1;
    expect(snapVerticalLanding(state, inside)).toBeNull(); // display: line-based reveal, not snapped
  });

  it('a multi-line footnote (not concealed) is not snapped', () => {
    const doc = 'x\\footnote{one\ntwo} y';
    const state = mountState(doc);
    expect(snapVerticalLanding(state, doc.indexOf('one'))).toBeNull();
  });

  it('nested hidden prefixes snap to the innermost visible text', () => {
    const doc = 'z \\textbf{\\emph{in}} z';
    const state = mountState(doc);
    const innerPrefix = doc.indexOf('\\emph') + 2;
    expect(snapVerticalLanding(state, innerPrefix)).toBe(doc.indexOf('in}'));
  });

  it('a landing in the OUTER prefix of a nested command iterates to the first visible character', () => {
    // FINDINGS.md #5 (R-V5): the outer command's argument start IS the inner
    // command's hidden prefix, so a one-shot snap parked the caret inside the
    // merged hidden run (both commands popped open). The snap must reach a
    // fixpoint: the first genuinely visible character.
    const doc = 'lead words \\textbf{\\emph{xy}} tail';
    const state = mountState(doc);
    const outerPrefix = doc.indexOf('\\textbf') + 3; // inside `\textbf{`
    expect(snapVerticalLanding(state, outerPrefix)).toBe(doc.indexOf('xy'));
    // The exact boundary between the two hidden prefixes is inside the merged
    // hidden range too and must settle the same way.
    expect(snapVerticalLanding(state, doc.indexOf('\\emph'))).toBe(doc.indexOf('xy'));
  });

  it('an \\href whose url spans lines keeps its raw prefix, so it is not snapped', () => {
    const doc = 'x \\href{http://a\nb}{text} y';
    const state = mountState(doc);
    expect(snapVerticalLanding(state, doc.indexOf('\\href') + 2)).toBeNull();
  });

  it('Mixed shows every command prefix, so only math snaps', () => {
    const doc = 'aa \\emph{word} \\ref{fig:m} $x+y$ bb';
    const state = texView(doc, { viewMode: 'mixed' }).state;
    expect(snapVerticalLanding(state, doc.indexOf('\\emph') + 2)).toBeNull();
    expect(snapVerticalLanding(state, doc.indexOf('\\ref') + 2)).toBeNull();
    expect(snapVerticalLanding(state, doc.indexOf('$') + 1)).toBe(doc.indexOf('$') - 1);
  });

  it('triple nesting still settles on visible text', () => {
    const doc = 'a \\textbf{\\emph{\\texttt{q}}} b';
    const state = mountState(doc);
    expect(snapVerticalLanding(state, doc.indexOf('\\textbf') + 2)).toBe(doc.indexOf('q}'));
  });
});

describe('ArrowDown transit (mounted)', () => {
  const mount = (docText: string, cursor: number): EditorView => texView(docText, { cursor });

  const contentText = (view: EditorView) =>
    view.dom.querySelector('.cm-content')!.textContent ?? '';

  function pressDown(view: EditorView): void {
    view.contentDOM.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true, cancelable: true }),
    );
  }

  it('does not land inside (or reveal) inline math when moving down', () => {
    const doc = 'aaaa aaaa\naa $x+y$ bb\ncccc cccc';
    const view = mount(doc, 5); // line 1, a column that lands mid-math below
    pressDown(view);
    const head = view.state.selection.main.head;
    const regions = scanMathRegions(doc);
    const inMath = regions.some((r) => head >= r.from && head < r.to);
    expect(inMath).toBe(false);
    expect(contentText(view)).not.toContain('$x+y$');
  });
});

describe('document edges fall through to CodeMirror', () => {
  // The keymap owns Up/Down for an empty caret, so it must hand the press
  // BACK when the caret cannot move: Up on the first line, Down on the last.
  // Claiming a press that moved nothing swallowed the fallbacks below it
  // (CM6's own line commands, and the browser's native caret motion), so Up
  // at the top of a document did nothing at all. The md twin has had this
  // guard since it was written.
  const mount = (docText: string, cursor: number): EditorView => texView(docText, { cursor });

  /** A binding appended after the editor's own config at the SAME precedence
   *  as this keymap, so it runs only once the vertical-motion command has
   *  declined the press. (It has to sit inside Prec.high: CM6's own
   *  `cursorLineUp` at default precedence claims the press either way, which
   *  is exactly the decision this keymap must leave to it.) Returns false so
   *  the rest of the chain still runs. */
  function watchFallthrough(view: EditorView, key: string): () => boolean {
    let reached = false;
    view.dispatch({
      effects: StateEffect.appendConfig.of(
        Prec.high(keymap.of([{ key, run: () => { reached = true; return false; } }])),
      ),
    });
    return () => reached;
  }

  function press(view: EditorView, key: string): void {
    view.contentDOM.dispatchEvent(
      new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true }),
    );
  }

  it('Up at the start of the document does not claim the press', () => {
    const view = mount('first line\nsecond line', 0);
    const fellThrough = watchFallthrough(view, 'ArrowUp');
    press(view, 'ArrowUp');
    expect(fellThrough()).toBe(true);
    expect(view.state.selection.main.head).toBe(0);
  });

  it('Down at the end of the document does not claim the press', () => {
    const doc = 'first line\nsecond line';
    const view = mount(doc, doc.length);
    const fellThrough = watchFallthrough(view, 'ArrowDown');
    press(view, 'ArrowDown');
    expect(fellThrough()).toBe(true);
    expect(view.state.selection.main.head).toBe(doc.length);
  });
});

// Goal-column persistence across short lines and collapsed fences is
// geometric (pixel goals, measured rows) and NOT testable in jsdom — the
// Playwright vertical-motion harness covers it (same split as tex-list's
// caret-motion tests).
