import { describe, it, expect, afterEach } from 'vitest';
import type { EditorView } from '@codemirror/view';
import { destroyViews, texView } from './helpers/views';

/**
 * The rendered slide card. Class-level assertions only — jsdom has no layout,
 * so the geometry (where the card's edges actually land, whether a click
 * inside the bottom padding resolves to the right line) is checked in
 * Tests/browser/run.mjs instead.
 */

// Caret at the very end, which every fixture below keeps OUTSIDE the frame,
// so no fence is selection-revealed.
const mount = (doc: string): EditorView => texView(doc, { cursor: 'end' });

afterEach(destroyViews);

const text = (view: EditorView): string =>
  view.dom.querySelector('.cm-content')!.textContent ?? '';
const slides = (view: EditorView): HTMLElement[] =>
  Array.from(view.dom.querySelectorAll('.cm-line.cm-slide'));

const BEAMER = '\\documentclass{beamer}\n';

describe('slide card decorations', () => {
  it('marks every row of the frame as a slide line', () => {
    const view = mount(`${BEAMER}\\begin{frame}{Roadmap}\nalpha\nbeta\n\\end{frame}\nafter`);
    // header + two body rows + the foot. The \end{frame} row keeps its place
    // as the card's foot; only its text is hidden.
    expect(slides(view)).toHaveLength(4);
  });

  it('puts the top class and the slide number on the header row', () => {
    const view = mount(`${BEAMER}\\begin{frame}{Roadmap}\nalpha\n\\end{frame}\nafter`);
    const top = view.dom.querySelector('.cm-line.cm-slide-top') as HTMLElement;
    expect(top).not.toBeNull();
    expect(top.dataset.slide).toBe('1');
  });

  it('numbers slides in document order', () => {
    const view = mount(
      `${BEAMER}\\begin{frame}{One}\na\n\\end{frame}\n` +
        `\\begin{frame}{Two}\nb\n\\end{frame}\n` +
        `after`,
    );
    const tops = Array.from(
      view.dom.querySelectorAll('.cm-line.cm-slide-top'),
    ) as HTMLElement[];
    expect(tops.map((t) => t.dataset.slide)).toEqual(['1', '2']);
  });

  it('hides the closing fence text but keeps its row as the card foot', () => {
    const view = mount(`${BEAMER}\\begin{frame}{Roadmap}\nalpha\nomega\n\\end{frame}\nafter`);
    expect(text(view)).not.toContain('\\end{frame}');
    const bottom = view.dom.querySelector('.cm-line.cm-slide-bottom') as HTMLElement;
    // The foot is an empty row of the card's own width, NOT the last body row:
    // that is what lets the card close no matter what its last element is.
    expect(bottom.textContent).toBe('');
    expect(bottom.classList.contains('cm-callout')).toBe(false);
  });

  it('replaces the open fence with a header carrying the title and subtitle', () => {
    const view = mount(
      `${BEAMER}\\begin{frame}{Bayesian updating}{a worked example}\na\n\\end{frame}\nafter`,
    );
    expect(text(view)).not.toContain('\\begin{frame}');
    const title = view.dom.querySelector('.cm-slide-title');
    const subtitle = view.dom.querySelector('.cm-slide-subtitle');
    expect(title?.textContent).toBe('Bayesian updating');
    expect(subtitle?.textContent).toBe('a worked example');
  });

  it('omits the subtitle element when the frame has no subtitle', () => {
    const view = mount(`${BEAMER}\\begin{frame}{Solo}\na\n\\end{frame}\nafter`);
    expect(view.dom.querySelector('.cm-slide-title')?.textContent).toBe('Solo');
    expect(view.dom.querySelector('.cm-slide-subtitle')).toBeNull();
  });

  it('renders the \\frametitle form as the same header, on the frametitle row', () => {
    const view = mount(
      `${BEAMER}\\begin{frame}[t]\n\\frametitle{Identification}\n\\framesubtitle{three conditions}\na\n\\end{frame}\nafter`,
    );
    // The bare open fence collapses; the title band moves onto \frametitle.
    expect(text(view)).not.toContain('\\begin{frame}');
    const top = view.dom.querySelector('.cm-line.cm-slide-top') as HTMLElement;
    expect(top.textContent).toContain('Identification');
    expect(top.dataset.slide).toBe('1');
  });

  it('conceals the \\frametitle command, leaving only the title text', () => {
    const view = mount(
      `${BEAMER}\\begin{frame}[t]\n\\frametitle{Identification}\na\n\\end{frame}\nafter`,
    );
    expect(text(view)).not.toContain('\\frametitle{');
    const title = view.dom.querySelector('.cm-tex-frametitle');
    expect(title?.textContent).toBe('Identification');
  });

  it('conceals \\framesubtitle the same way', () => {
    const view = mount(
      `${BEAMER}\\begin{frame}[t]\n\\frametitle{Identification}\n\\framesubtitle{three conditions}\na\n\\end{frame}\nafter`,
    );
    expect(text(view)).not.toContain('\\framesubtitle{');
    expect(view.dom.querySelector('.cm-tex-framesubtitle')?.textContent).toBe(
      'three conditions',
    );
  });

  it('reveals the raw \\frametitle source when the caret is on it', () => {
    const view = mount(
      `${BEAMER}\\begin{frame}[t]\n\\frametitle{Identification}\na\n\\end{frame}\nafter`,
    );
    const titleLine = view.state.doc.line(3);
    view.dispatch({ selection: { anchor: titleLine.from + 4 } });
    expect(text(view)).toContain('\\frametitle{Identification}');
  });

  it('renders the \\frametitle flush with the band, not at the source indent', () => {
    // Both surface syntaxes must produce the SAME card. The brace form's
    // header is a widget starting at the line start; the command form keeps
    // real source, whose leading indent would otherwise push the title right.
    const view = mount(
      `${BEAMER}\\begin{frame}[t]\n    \\frametitle{Identification}\na\n\\end{frame}\nafter`,
    );
    const top = view.dom.querySelector('.cm-line.cm-slide-top') as HTMLElement;
    expect(top.textContent).toBe('Identification');
  });

  it('keeps the \\framesubtitle row inside the title band', () => {
    const view = mount(
      `${BEAMER}\\begin{frame}[t]\n    \\frametitle{Identification}\n    \\framesubtitle{three conditions}\na\n\\end{frame}\nafter`,
    );
    const band = Array.from(
      view.dom.querySelectorAll('.cm-line.cm-slide-band'),
    ) as HTMLElement[];
    expect(band.map((b) => b.textContent)).toEqual([
      'Identification',
      'three conditions',
    ]);
    // The band's closing hairline belongs to its LAST row, not the title row.
    expect(band[0].classList.contains('cm-slide-band-end')).toBe(false);
    expect(band[1].classList.contains('cm-slide-band-end')).toBe(true);
  });

  it('closes the band on the header row itself in the brace form', () => {
    const view = mount(
      `${BEAMER}\\begin{frame}{T}{S}\na\n\\end{frame}\nafter`,
    );
    const top = view.dom.querySelector('.cm-line.cm-slide-top') as HTMLElement;
    expect(top.classList.contains('cm-slide-band')).toBe(true);
    expect(top.classList.contains('cm-slide-band-end')).toBe(true);
  });

  it('restores the indent and the command when the caret enters the title', () => {
    const view = mount(
      `${BEAMER}\\begin{frame}[t]\n    \\frametitle{Identification}\na\n\\end{frame}\nafter`,
    );
    const titleLine = view.state.doc.line(3);
    view.dispatch({ selection: { anchor: titleLine.from + 8 } });
    const top = view.dom.querySelector('.cm-line.cm-slide-top') as HTMLElement;
    expect(top.textContent).toBe('    \\frametitle{Identification}');
  });

  it('reveals the indent but keeps the command concealed at the line start', () => {
    // Per-construct reveal: the caret is on the ROW (so the row's own indent
    // comes back) but outside the \frametitle command, which stays rendered.
    // Same rule every other concealed construct follows.
    const view = mount(
      `${BEAMER}\\begin{frame}[t]\n    \\frametitle{Identification}\na\n\\end{frame}\nafter`,
    );
    view.dispatch({ selection: { anchor: view.state.doc.line(3).from } });
    const top = view.dom.querySelector('.cm-line.cm-slide-top') as HTMLElement;
    expect(top.textContent).toBe('    Identification');
  });

  it('reveals the raw open fence when the caret is on it', () => {
    const view = mount(`${BEAMER}\\begin{frame}{Roadmap}\nalpha\n\\end{frame}\nafter`);
    const openLine = view.state.doc.line(2);
    view.dispatch({ selection: { anchor: openLine.from + 3 } });
    expect(text(view)).toContain('\\begin{frame}{Roadmap}');
  });

  it('reveals the collapsed closing fence when the caret is on it', () => {
    const view = mount(`${BEAMER}\\begin{frame}{Roadmap}\nalpha\n\\end{frame}\nafter`);
    const closeLine = view.state.doc.line(4);
    view.dispatch({ selection: { anchor: closeLine.from } });
    expect(text(view)).toContain('\\end{frame}');
  });

  it('draws nothing in a document that is not beamer', () => {
    const view = mount('\\documentclass{article}\n\\begin{frame}\na\n\\end{frame}\nafter');
    expect(slides(view)).toHaveLength(0);
    expect(text(view)).toContain('\\begin{frame}');
  });

  it('carries the card through a display-math block', () => {
    // A block-replace widget is not a .cm-line, so the per-line rules cannot
    // reach it: without the frameBlockAt hand-off the card's side edges break
    // open around every display equation.
    const view = mount(
      `${BEAMER}\\begin{frame}{Bayes}\nalpha\n\\[ x = 1 \\]\nomega\n\\end{frame}\nafter`,
    );
    const math = view.dom.querySelector('.cm-tex-math-display');
    expect(math).not.toBeNull();
    expect(math!.classList.contains('cm-slide')).toBe(true);
  });

  it('closes a frame ending in display math on the foot, not on the widget', () => {
    // A block widget never carries the card's bottom: the foot row does. That
    // is why frameBlockAt, unlike calloutBlockAt, reports no `bottom`.
    const view = mount(
      `${BEAMER}\\begin{frame}{Bayes}\nalpha\n\\[ x = 1 \\]\n\\end{frame}\nafter`,
    );
    const math = view.dom.querySelector('.cm-tex-math-display')!;
    expect(math.classList.contains('cm-slide')).toBe(true);
    expect(math.classList.contains('cm-slide-bottom')).toBe(false);
    const bottom = view.dom.querySelector('.cm-line.cm-slide-bottom') as HTMLElement;
    expect(bottom.textContent).toBe('');
    expect(text(view)).not.toContain('\\end{frame}');
  });

  it('still closes the card when the last element is a block', () => {
    // Regression: `\\end{block}` collapses (callout plugin) and `\\end{frame}`
    // collapses (frame plugin), so EVERY candidate row for the card's bottom
    // edge had been removed by another plugin and the card never closed.
    const view = mount(
      `${BEAMER}\\begin{frame}{B}\nlead\n\\begin{block}{T}\nbody\n\\end{block}\n\\end{frame}\nafter`,
    );
    expect(view.dom.querySelector('.cm-line.cm-slide-bottom')).not.toBeNull();
  });

  it('still closes the card when the last elements are a theorem and a proof', () => {
    const view = mount(
      `${BEAMER}\\begin{frame}{D}\n\\begin{theorem}\ns\n\\end{theorem}\n\\begin{proof}\ni\n\\end{proof}\n\\end{frame}\nafter`,
    );
    expect(view.dom.querySelector('.cm-line.cm-slide-bottom')).not.toBeNull();
  });

  it('closes the card on a row of its own, never on a nested box row', () => {
    // The card's bottom edge must span the card's own width. A nested callout
    // row is inset on both sides, so drawing the card's foot there would make
    // the bottom edge narrower than the sides it joins.
    const view = mount(
      `${BEAMER}\\begin{frame}{B}\n\\begin{block}{T}\nbody\n\\end{block}\n\\end{frame}\nafter`,
    );
    const bottom = view.dom.querySelector('.cm-line.cm-slide-bottom') as HTMLElement;
    expect(bottom).not.toBeNull();
    expect(bottom.classList.contains('cm-callout')).toBe(false);
  });

  it('dedents the frame body by its common indent', () => {
    const view = mount(
      `${BEAMER}\\begin{frame}{T}\n    alpha\n    beta\n\\end{frame}\nafter`,
    );
    const rows = slides(view).map((r) => r.textContent);
    expect(rows).toContain('alpha');
    expect(rows).toContain('beta');
  });

  it('preserves relative indentation inside the frame', () => {
    // Only the COMMON prefix goes. A nested level keeps the difference, or
    // nested lists would flatten.
    const view = mount(
      `${BEAMER}\\begin{frame}{T}\n    alpha\n        nested\n\\end{frame}\nafter`,
    );
    const rows = slides(view).map((r) => r.textContent);
    expect(rows).toContain('alpha');
    expect(rows).toContain('    nested');
  });

  it('dedents by the minimum, not by the first line', () => {
    const view = mount(
      `${BEAMER}\\begin{frame}{T}\n        deep\n  shallow\n\\end{frame}\nafter`,
    );
    const rows = slides(view).map((r) => r.textContent);
    expect(rows).toContain('      deep');
    expect(rows).toContain('shallow');
  });

  it('ignores blank lines when measuring the common indent', () => {
    const view = mount(
      `${BEAMER}\\begin{frame}{T}\n    alpha\n\n    beta\n\\end{frame}\nafter`,
    );
    const rows = slides(view).map((r) => r.textContent);
    expect(rows).toContain('alpha');
    expect(rows).toContain('beta');
  });

  it('leaves verbatim content exactly as written', () => {
    const view = mount(
      `${BEAMER}\\begin{frame}[fragile]{T}\n    \\begin{verbatim}\n    indented sample\n    \\end{verbatim}\n\\end{frame}\nafter`,
    );
    expect(text(view)).toContain('    indented sample');
  });

  it('restores the indent when the caret is on the line', () => {
    const view = mount(
      `${BEAMER}\\begin{frame}{T}\n    alpha\n\\end{frame}\nafter`,
    );
    view.dispatch({ selection: { anchor: view.state.doc.line(3).from } });
    const rows = slides(view).map((r) => r.textContent);
    expect(rows).toContain('    alpha');
  });

  it('keeps a nested block inside the card rather than ending it early', () => {
    const view = mount(
      `${BEAMER}\\begin{frame}{A result}\n\\begin{block}{Takeaway}\nconjugate\n\\end{block}\n\\end{frame}\nafter`,
    );
    const nested = view.dom.querySelector('.cm-line.cm-slide.cm-callout');
    expect(nested).not.toBeNull();
  });
});
