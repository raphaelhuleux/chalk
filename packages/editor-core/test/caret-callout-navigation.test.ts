import { describe, it, expect, afterEach } from 'vitest';
import { EditorSelection } from '@codemirror/state';
import { EditorView as EV } from '@codemirror/view';
import type { EditorView } from '@codemirror/view';
import { cursorCharLeft, cursorCharRight } from '@codemirror/commands';
import type { Language } from '../src/editor/setup';
import { _testing as mdArrows } from '../src/editor/md-math-plugin';
import { _testing as texArrows } from '../src/editor/tex-math';
import { destroyViews, langView } from './helpers/views';

/**
 * Caret movement across callouts and collapsed math: ONE DOCUMENT LINE per
 * press, and arrowing onto a collapsed element reveals it (owner-specified
 * model — "Up from below the box lands on the ::: and shows it").
 *
 * The collapsed closing fence occupies no visual row (block-replaced), so
 * CM6's geometry-driven moveByLine can't stop on it — the fence-stop keymap
 * (makeFenceStopKeymap) intercepts Up/Down when the adjacent document line is
 * a collapsed fence and places the caret there explicitly; the reveal then
 * happens via the ordinary selection-on-line check. The enter-math keymaps
 * keep plain document adjacency: with the fence as its own stop, no handler
 * ever needs to look "through" a fence.
 *
 * Where a handler claims the key, tests drive REAL ArrowUp/ArrowDown keydown
 * events (deterministic in jsdom — no geometry involved). No-fire cases call
 * the exported handlers directly, since a declined key would fall through to
 * CM6's geometric default, which jsdom can't measure.
 */

const mount = (doc: string, language: Language, cursor: number): EditorView =>
  langView(doc, language, { ensureTree: true, cursor });

afterEach(destroyViews);

const line = (view: EditorView, n: number) => view.state.doc.line(n);
const head = (view: EditorView) => view.state.selection.main.head;
const contentText = (view: EditorView) => view.dom.querySelector('.cm-content')!.textContent ?? '';

/** Dispatch a real keydown so the full Prec.high keymap chain runs. */
function press(view: EditorView, key: string): void {
  view.contentDOM.dispatchEvent(
    new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true }),
  );
}

// ---------------------------------------------------------------------------
// md: one document line per press — the collapsed fence is a stop that reveals
// ---------------------------------------------------------------------------

// 1 open, 2 statement, 3-5 math, 6 fence, 7 after.
const MD_MATH_ENDING = '::: {#thm-a}\nStatement.\n$$\nx+1\n$$\n:::\nafter';
// 1 open, 2 body, 3 fence, 4-6 math, 7 after.
const MD_MATH_AFTER = '::: {.proof}\nbody\n:::\n$$\nx\n$$\nafter';
// 1 open, 2 body, 3 fence, 4 after.
const MD_TEXT_ENDING = '::: {.proof}\nbody\n:::\nafter';

describe('md: vertical motion, fence-stop model', () => {
  it('Up from below a callout stops ON the fence and reveals it', () => {
    const view = mount(MD_TEXT_ENDING, 'md', 0);
    view.dispatch({ selection: EditorSelection.cursor(line(view, 4).from) }); // 'after'
    expect(contentText(view)).not.toContain(':::');
    press(view, 'ArrowUp');
    expect(head(view)).toBe(line(view, 3).from); // ON the fence line
    expect(contentText(view)).toContain(':::'); // revealed under the caret
  });

  it('Down from the last body line stops ON the fence and reveals it', () => {
    const view = mount(MD_TEXT_ENDING, 'md', 0);
    view.dispatch({ selection: EditorSelection.cursor(line(view, 2).from) }); // 'body'
    press(view, 'ArrowDown');
    expect(head(view)).toBe(line(view, 3).from);
    expect(contentText(view)).toContain(':::');
  });

  it('clamps the goal column into the short fence text', () => {
    const view = mount('::: {.proof}\nbody\n:::\na much longer after line', 'md', 0);
    view.dispatch({ selection: EditorSelection.cursor(line(view, 4).from + 15) });
    press(view, 'ArrowUp');
    expect(head(view)).toBe(line(view, 3).to); // clamped to ::: end
  });

  it('Up from after a MATH-ENDING callout: first the fence, then into the math', () => {
    const view = mount(MD_MATH_ENDING, 'md', 0);
    view.dispatch({ selection: EditorSelection.cursor(line(view, 7).from) }); // 'after'
    press(view, 'ArrowUp'); // stop 1: the fence, revealed
    expect(head(view)).toBe(line(view, 6).from);
    expect(contentText(view)).toContain(':::');
    press(view, 'ArrowUp'); // stop 2: into the math (enter-math keymap)
    expect(head(view)).toBe(line(view, 5).from); // start of closing $$ line
  });

  it('Down from callout body toward following math: fence first, then the math', () => {
    const view = mount(MD_MATH_AFTER, 'md', 0);
    view.dispatch({ selection: EditorSelection.cursor(line(view, 2).from) }); // 'body'
    press(view, 'ArrowDown'); // stop 1: the fence
    expect(head(view)).toBe(line(view, 3).from);
    press(view, 'ArrowDown'); // stop 2: into the math, column preserved
    expect(head(view)).toBe(line(view, 4).from); // column 0 → column 0
  });

  it('enter-math does not fire across a VISIBLE intervening line', () => {
    const view = mount('$$\nx\n$$\ntext\nafter', 'md', 0);
    view.dispatch({ selection: EditorSelection.cursor(line(view, 5).from) }); // 'after'
    expect(mdArrows.mdEnterDisplayMathFromBelow(view)).toBe(false);
  });

  it('neither handler claims Down onto a callout open fence (visible label row)', () => {
    const view = mount('above\n' + MD_MATH_ENDING, 'md', 0);
    view.dispatch({ selection: EditorSelection.cursor(0) }); // 'above'
    // The next document line is the open fence — a VISIBLE row that default
    // one-row motion reaches on its own; both handlers must stay out.
    expect(mdArrows.mdEnterDisplayMathFromAbove(view)).toBe(false);
    expect(head(view)).toBe(0); // nothing moved the caret behind our back
  });
});

// ---------------------------------------------------------------------------
// md: a collapsed `## Title` line is a stop too (M-19)
// ---------------------------------------------------------------------------

// 1 open, 2 title (collapsed into the label widget), 3 body, 4 fence, 5 after.
const MD_HEADING_TITLE = '::: {#thm-a}\n## My Title\nbody\n:::\nafter';

describe('md: vertical motion stops on a collapsed title line', () => {
  it('ArrowUp from below: fence (revealed), body, then ON the title (revealed)', () => {
    const view = mount(MD_HEADING_TITLE, 'md', 0);
    view.dispatch({ selection: EditorSelection.cursor(line(view, 5).from) }); // 'after' col 0
    expect(contentText(view)).not.toContain('##'); // title folded into the widget

    press(view, 'ArrowUp'); // stop 1: the collapsed :::, revealed
    expect(head(view)).toBe(line(view, 4).from);
    expect(contentText(view)).toContain(':::');

    // Stop 2 (fence → body) is DEFAULT motion — no handler claims it, and
    // jsdom can't run CM6's geometric moveByLine (see the header comment) —
    // so place the caret where that press lands and re-collapse the fence.
    view.dispatch({ selection: EditorSelection.cursor(line(view, 3).from) }); // 'body'
    expect(contentText(view)).not.toContain(':::'); // fence re-collapsed
    expect(contentText(view)).not.toContain('##'); // title still collapsed

    press(view, 'ArrowUp'); // stop 3: ON the collapsed title line, revealed
    expect(head(view)).toBe(line(view, 2).from);
    expect(contentText(view)).toContain('## My Title');
  });

  it('ArrowDown from the line above stops ON the title line', () => {
    const view = mount(MD_HEADING_TITLE, 'md', 0);
    view.dispatch({ selection: EditorSelection.cursor(line(view, 1).from) }); // open fence
    press(view, 'ArrowDown');
    expect(head(view)).toBe(line(view, 2).from); // ON `## My Title`
    expect(contentText(view)).toContain('## My Title'); // revealed under the caret
  });
});

// ---------------------------------------------------------------------------
// tex: same seam, LaTeX surface syntax
// ---------------------------------------------------------------------------

const TEX_MATH_ENDING = '\\begin{theorem}\nStatement.\n$$\nx+1\n$$\n\\end{theorem}\nafter';
const TEX_MATH_AFTER = '\\begin{proof}\nbody\n\\end{proof}\n$$\nx\n$$\nafter';

describe('tex: vertical motion, fence-stop model', () => {
  it('Up from below stops on \\end{theorem} and reveals it, then enters the math', () => {
    const view = mount(TEX_MATH_ENDING, 'tex', 0);
    view.dispatch({ selection: EditorSelection.cursor(line(view, 7).from) }); // 'after'
    expect(contentText(view)).not.toContain('\\end{theorem}');
    press(view, 'ArrowUp');
    expect(head(view)).toBe(line(view, 6).from);
    expect(contentText(view)).toContain('\\end{theorem}');
    press(view, 'ArrowUp');
    expect(head(view)).toBe(line(view, 5).from); // closing $$ line of the math
  });

  it('Down from body: fence stop, then into following math', () => {
    const view = mount(TEX_MATH_AFTER, 'tex', 0);
    view.dispatch({ selection: EditorSelection.cursor(line(view, 2).from) }); // 'body'
    press(view, 'ArrowDown');
    expect(head(view)).toBe(line(view, 3).from); // \end{proof}, revealed
    press(view, 'ArrowDown');
    expect(head(view)).toBe(line(view, 4).from); // opening $$ line, column 0
  });

  it('enter-math does not fire across a visible intervening line', () => {
    const view = mount('$$\nx\n$$\ntext\nafter', 'tex', 0);
    view.dispatch({ selection: EditorSelection.cursor(line(view, 5).from) });
    expect(texArrows.enterDisplayMathFromBelow(view)).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Horizontal motion: one position per keypress, reveal on fence entry
// ---------------------------------------------------------------------------

describe('md: horizontal motion across the collapsed fence', () => {
  const DOC = '::: {.proof}\nbody\n:::\nafter'; // 1 open, 2 body, 3 fence, 4 after

  it('Right from the end of the last body line steps onto the fence and reveals it', () => {
    const view = mount(DOC, 'md', 0);
    view.dispatch({ selection: EditorSelection.cursor(line(view, 2).to) });
    expect(contentText(view)).not.toContain(':::');
    cursorCharRight(view);
    expect(head(view)).toBe(line(view, 3).from); // exactly one position
    expect(contentText(view)).toContain(':::'); // fence revealed for editing
  });

  it('Left from the start of the after-line steps onto the fence end and reveals it', () => {
    const view = mount(DOC, 'md', 0);
    view.dispatch({ selection: EditorSelection.cursor(line(view, 4).from) });
    cursorCharLeft(view);
    expect(head(view)).toBe(line(view, 3).to);
    expect(contentText(view)).toContain(':::');
  });

  it('stepping back out re-collapses the fence', () => {
    const view = mount(DOC, 'md', 0);
    view.dispatch({ selection: EditorSelection.cursor(line(view, 3).from) }); // on fence
    expect(contentText(view)).toContain(':::');
    cursorCharLeft(view); // back to end of 'body'
    expect(head(view)).toBe(line(view, 2).to);
    expect(contentText(view)).not.toContain(':::');
  });
});

describe('tex: horizontal motion across the collapsed fence', () => {
  const DOC = '\\begin{proof}\nbody\n\\end{proof}\nafter';

  it('Right from body end reveals the \\end line one position later', () => {
    const view = mount(DOC, 'tex', 0);
    view.dispatch({ selection: EditorSelection.cursor(line(view, 2).to) });
    expect(contentText(view)).not.toContain('\\end{proof}');
    cursorCharRight(view);
    expect(head(view)).toBe(line(view, 3).from);
    expect(contentText(view)).toContain('\\end{proof}');
  });
});

// ---------------------------------------------------------------------------
// Structural invariant: nothing about a callout is atomic — the caret may
// step anywhere, and reveal-on-entry does the rest. (Atomic ranges would make
// CM6 shove the caret across whole regions, the multi-line-jump failure mode.)
// ---------------------------------------------------------------------------

function isPositionAtomic(view: EditorView, pos: number): boolean {
  const providers = view.state.facet(EV.atomicRanges);
  for (const provide of providers) {
    let hit = false;
    provide(view).between(pos, pos, (from, to) => {
      if (from < pos && to > pos) {
        hit = true;
        return false;
      }
    });
    if (hit) return true;
  }
  return false;
}

describe('callout regions are never atomic', () => {
  it('md: open-fence, body, and closing-fence interiors all admit the caret', () => {
    const view = mount(MD_MATH_ENDING, 'md', 0);
    view.dispatch({ selection: EditorSelection.cursor(line(view, 7).from) });
    for (const n of [1, 2, 6]) {
      const l = line(view, n);
      const mid = Math.min(l.from + 1, l.to);
      expect(isPositionAtomic(view, mid), `line ${n}`).toBe(false);
    }
  });

  it('tex: same invariant', () => {
    const view = mount(TEX_MATH_ENDING, 'tex', 0);
    view.dispatch({ selection: EditorSelection.cursor(line(view, 7).from) });
    for (const n of [1, 2, 6]) {
      const l = line(view, n);
      const mid = Math.min(l.from + 1, l.to);
      expect(isPositionAtomic(view, mid), `line ${n}`).toBe(false);
    }
  });
});
