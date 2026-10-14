import { describe, it, expect, afterEach } from 'vitest';
import katex from 'katex';
import { EditorView } from '@codemirror/view';
import { destroyViews, langView } from './helpers/views';
import { countEquationNumbers } from './helpers/katex';

// KaTeX numbers `equation`/`align`/`gather` rows with a pure CSS counter
// (`counter-increment` on `.eqn-num:before`), which counts DOM order. CM6
// virtualizes the viewport, so with no correction the first equation ON
// SCREEN is always (1). The fix: every math widget carries its
// document-order number offset in `--chalk-eq-offset`, and the stylesheet
// resets the KaTeX counters per widget from that value. These tests lock
// the offset bookkeeping; the CSS side is a static rule.

const mount = (content: string, language: 'tex' | 'md'): EditorView =>
  langView(content, language);

afterEach(destroyViews);

function offsets(v: EditorView, selector: string): string[] {
  return Array.from(v.dom.querySelectorAll<HTMLElement>(selector)).map((el) =>
    el.style.getPropertyValue('--chalk-eq-offset'),
  );
}

describe('countEquationNumbers', () => {
  it('counts one per numbered row and zero for starred/tagged/plain forms', () => {
    const render = (tex: string): string | null => {
      try {
        return katex.renderToString(tex, { displayMode: true, throwOnError: true });
      } catch {
        return null;
      }
    };
    expect(countEquationNumbers(render('\\begin{equation}a=b\\end{equation}'))).toBe(1);
    expect(countEquationNumbers(render('\\begin{equation*}a=b\\end{equation*}'))).toBe(0);
    expect(countEquationNumbers(render('\\begin{align}x&=1\\\\y&=2\\end{align}'))).toBe(2);
    expect(countEquationNumbers(render('\\begin{align}x&=1\\notag\\\\y&=2\\end{align}'))).toBe(1);
    expect(countEquationNumbers(render('\\begin{equation}a=b\\tag{A}\\end{equation}'))).toBe(0);
    expect(countEquationNumbers(render('a=b'))).toBe(0);
    expect(countEquationNumbers(null)).toBe(0);
  });
});

describe('tex equation-number offsets', () => {
  it('assigns document-order offsets across environments', () => {
    const v = mount(
      [
        'intro',
        '\\begin{equation}a=b\\end{equation}',
        'text',
        '\\begin{align}x&=1\\\\y&=2\\end{align}',
        'text',
        '\\begin{equation*}c=d\\end{equation*}',
        'text',
        '\\begin{equation}e=f\\end{equation}',
      ].join('\n'),
      'tex',
    );
    // equation → 1 number, align → 2, equation* → 0, equation → 1.
    expect(offsets(v, '.cm-tex-math-display')).toEqual(['0', '1', '3', '3']);
  });

  it('gives the edit-mode preview the same offset as the widget it replaces', () => {
    const v = mount(
      [
        'intro',
        '\\begin{equation}a=b\\end{equation}',
        '\\begin{equation}c=d\\end{equation}',
      ].join('\n'),
      'tex',
    );
    // Park the caret inside the SECOND equation: its source is revealed and a
    // preview widget renders below with the offset of one preceding number.
    const pos = v.state.doc.line(3).from + 5;
    v.dispatch({ selection: { anchor: pos } });
    const preview = v.dom.querySelector<HTMLElement>('.cm-tex-math-preview');
    expect(preview).not.toBeNull();
    expect(preview!.style.getPropertyValue('--chalk-eq-offset')).toBe('1');
  });

  it('leaves inline math without an offset', () => {
    const v = mount('intro\ntext $a=b$ more', 'tex');
    const inline = v.dom.querySelector<HTMLElement>('.cm-tex-math-inline');
    expect(inline).not.toBeNull();
    expect(inline!.style.getPropertyValue('--chalk-eq-offset')).toBe('');
  });
});

describe('md equation-number offsets', () => {
  it('assigns document-order offsets to $$ blocks containing numbered envs', () => {
    const v = mount(
      [
        'intro',
        '$$\\begin{align}a&=1\\\\b&=2\\end{align}$$',
        'text',
        '$$\\begin{equation}c=3\\end{equation}$$',
      ].join('\n'),
      'md',
    );
    expect(offsets(v, '.cm-math-display')).toEqual(['0', '2']);
  });

  it('gives the md edit-mode preview the running offset', () => {
    const v = mount(
      [
        'intro',
        '$$\\begin{equation}a=1\\end{equation}$$',
        'text',
        '$$\\begin{equation}b=2\\end{equation}$$',
      ].join('\n'),
      'md',
    );
    const pos = v.state.doc.line(4).from + 3;
    v.dispatch({ selection: { anchor: pos } });
    const preview = v.dom.querySelector<HTMLElement>('.cm-math-preview');
    expect(preview).not.toBeNull();
    expect(preview!.style.getPropertyValue('--chalk-eq-offset')).toBe('1');
  });
});
