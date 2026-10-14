import { describe, it, expect, afterEach } from 'vitest';
import { EditorSelection } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import type { Language } from '../src/editor/setup';
import { destroyViews, langView } from './helpers/views';

/**
 * Audit check A: regression matrix for the fence-collapse caret model as
 * consumed by the NEW structures (tex lists, eq-numbered math). Every past
 * caret fix's invariant is pinned somewhere; this file covers the audit's
 * proposed tests 5-9 (list fence column clamp, stacked fence walks, math
 * absorbing list fences, eq-offset behavior under absorb and invalid input).
 * Tests drive REAL ArrowUp/ArrowDown keydowns (deterministic in jsdom).
 */

const mount = (doc: string, language: Language, cursor: number): EditorView =>
  langView(doc, language, { ensureTree: true, cursor });

afterEach(destroyViews);

const line = (v: EditorView, n: number) => v.state.doc.line(n);
const head = (v: EditorView) => v.state.selection.main.head;
const headLine = (v: EditorView) => v.state.doc.lineAt(head(v)).number;
const headCol = (v: EditorView) => head(v) - v.state.doc.lineAt(head(v)).from;
const contentText = (v: EditorView) =>
  v.dom.querySelector('.cm-content')!.textContent ?? '';

function press(view: EditorView, key: string): void {
  view.contentDOM.dispatchEvent(
    new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true }),
  );
}

// ---------------------------------------------------------------------------
// Audit test 5: list fence-stop clamps the goal column
// ---------------------------------------------------------------------------

describe('tex list fence stop (0b32deb consumers)', () => {
  const DOC = [
    'intro line that is long enough', // 1
    '\\begin{enumerate}', // 2 (collapsed open fence)
    '\\item a', // 3
    '\\item b', // 4
    '\\end{enumerate}', // 5 (collapsed close fence)
    'after', // 6
  ].join('\n');

  it('ArrowDown from a long line stops ON the open fence, column-clamped', () => {
    const v = mount(DOC, 'tex', 0);
    v.dispatch({ selection: EditorSelection.cursor(line(v, 1).from + 20) });
    press(v, 'ArrowDown');
    expect(headLine(v)).toBe(2);
    expect(headCol(v)).toBe(Math.min(20, line(v, 2).length));
    // Fence revealed: its raw text is visible.
    expect(contentText(v)).toContain('\\begin{enumerate}');
  });

  it('ArrowUp from below stops ON the close fence and reveals it', () => {
    const v = mount(DOC, 'tex', 0);
    v.dispatch({ selection: EditorSelection.cursor(line(v, 6).from) });
    press(v, 'ArrowUp');
    expect(headLine(v)).toBe(5);
    expect(headCol(v)).toBe(0);
    expect(contentText(v)).toContain('\\end{enumerate}');
  });
});

// ---------------------------------------------------------------------------
// Audit test 6: stacked fences (list close, then callout close) walk one line
// per press, each stop revealing its own fence
// ---------------------------------------------------------------------------

describe('stacked list + theorem fences', () => {
  const DOC = [
    '\\begin{theorem}', // 1 (callout open, collapsed into label)
    'S:', // 2
    '\\begin{itemize}', // 3
    '\\item x', // 4
    '\\end{itemize}', // 5 (list close fence)
    '\\end{theorem}', // 6 (callout close fence)
    'after', // 7
  ].join('\n');

  it('ArrowUp walks: after → \\end{theorem} → \\end{itemize} → \\item x', () => {
    const v = mount(DOC, 'tex', 0);
    v.dispatch({ selection: EditorSelection.cursor(line(v, 7).from) });

    press(v, 'ArrowUp');
    expect(headLine(v)).toBe(6);
    expect(headCol(v)).toBe(0);
    expect(contentText(v)).toContain('\\end{theorem}');

    press(v, 'ArrowUp');
    expect(headLine(v)).toBe(5);
    expect(headCol(v)).toBe(0);
    expect(contentText(v)).toContain('\\end{itemize}');
    // The next step (fence → \item x) is plain geometric motion that no
    // handler claims — jsdom can't execute it (documented harness limit in
    // caret-callout-navigation.test.ts). Both handler-claimed stops above
    // are the regression surface.
  });
});

// ---------------------------------------------------------------------------
// Audit test 7: display math directly above list close fences — the math
// widget absorbs the fences; arrow entry still stops on each element
// ---------------------------------------------------------------------------

describe('math absorbing list fences', () => {
  const DOC = [
    '\\begin{enumerate}', // 1
    '\\item a', // 2
    '\\[x=1\\]', // 3 (display math, last body element)
    '\\end{enumerate}', // 4 (absorbed by the math widget while collapsed)
    'after', // 5
  ].join('\n');

  it('collapsed: the math widget absorbs the fence (no raw \\end{enumerate})', () => {
    const v = mount(DOC, 'tex', 0);
    v.dispatch({ selection: EditorSelection.cursor(line(v, 5).from) });
    expect(contentText(v)).not.toContain('\\end{enumerate}');
  });

  it('ArrowUp from below stops ON the fence line and reveals it', () => {
    const v = mount(DOC, 'tex', 0);
    v.dispatch({ selection: EditorSelection.cursor(line(v, 5).from) });
    press(v, 'ArrowUp');
    expect(headLine(v)).toBe(4);
    expect(contentText(v)).toContain('\\end{enumerate}');
    // Next press continues into the math's closing line.
    press(v, 'ArrowUp');
    expect(headLine(v)).toBe(3);
  });
});

// ---------------------------------------------------------------------------
// Audit tests 8-9: eq-offset under callout absorb and under invalid input
// ---------------------------------------------------------------------------

describe('eq-offset integration (uncommitted eq-numbering feature)', () => {
  it('a theorem-absorbed equation still numbers, and the next one offsets by 1', () => {
    const v = mount(
      [
        '\\begin{theorem}',
        'T.',
        '\\begin{equation}',
        'E=mc^2',
        '\\end{equation}',
        '\\end{theorem}',
        'mid',
        '\\begin{equation}',
        'F=ma',
        '\\end{equation}',
        'after',
      ].join('\n'),
      'tex',
      0,
    );
    // Caret far away: both widgets rendered. The theorem's close fence is
    // absorbed by the first math widget (no raw \end{theorem}).
    v.dispatch({ selection: EditorSelection.cursor(v.state.doc.length) });
    expect(contentText(v)).not.toContain('\\end{theorem}');
    const offsets = Array.from(
      v.dom.querySelectorAll<HTMLElement>('.cm-tex-math-display'),
    ).map((el) => el.style.getPropertyValue('--chalk-eq-offset'));
    expect(offsets).toEqual(['0', '1']);
  });

  it('an invalid block contributes its SOURCE count so later numbers stay stable', () => {
    const v = mount(
      [
        '\\begin{equation}',
        'a=1',
        '\\end{equation}',
        '\\begin{equation}',
        '\\frac{1}', // invalid: renders as raw fallback
        '\\end{equation}',
        '\\begin{equation}',
        'c=3',
        '\\end{equation}',
        'after',
      ].join('\n'),
      'tex',
      0,
    );
    // Caret on the trailing plain line: all three blocks stay rendered.
    v.dispatch({ selection: EditorSelection.cursor(v.state.doc.length) });
    const displays = Array.from(
      v.dom.querySelectorAll<HTMLElement>('.cm-tex-math-display'),
    );
    expect(displays).toHaveLength(3);
    // The middle block is an error fallback but still occupies number (2):
    // the third block's offset stays 2 whether or not block 2 rendered.
    expect(displays[2].style.getPropertyValue('--chalk-eq-offset')).toBe('2');
    expect(displays[1].className).toContain('cm-tex-math-error');
  });
});
