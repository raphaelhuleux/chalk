import { describe, it, expect } from 'vitest';
import { EditorState } from '@codemirror/state';
import { markdown } from '@codemirror/lang-markdown';
import { ensureSyntaxTree } from '@codemirror/language';
import { mathSyntax } from '../src/editor/md-math-plugin';
import { highlightSyntax } from '../src/editor/md-highlight-plugin';
import { extractOutline, scanTexFigures } from '../src/editor/outline';

function mdState(doc: string): EditorState {
  const state = EditorState.create({
    doc,
    extensions: [markdown({ extensions: [mathSyntax, highlightSyntax] })],
  });
  ensureSyntaxTree(state, state.doc.length, 5000);
  return state;
}

function texState(doc: string): EditorState {
  // tex extraction is a plain regex/line scan — no language extension needed.
  return EditorState.create({ doc });
}

describe('extractOutline — markdown headings', () => {
  it('captures ATX headings with kind, level, title, and 1-based line', () => {
    const doc = ['# Title', '', 'intro', '', '## Section A', '', '### Sub', '', '## Section B'].join(
      '\n',
    );
    const items = extractOutline(mdState(doc), 'md');
    expect(items).toEqual([
      { kind: 'heading', level: 1, title: 'Title', line: 1 },
      { kind: 'heading', level: 2, title: 'Section A', line: 5 },
      { kind: 'heading', level: 3, title: 'Sub', line: 7 },
      { kind: 'heading', level: 2, title: 'Section B', line: 9 },
    ]);
  });

  it('strips a closing ATX run (## Title ##)', () => {
    const items = extractOutline(mdState('## Title ##'), 'md');
    expect(items).toEqual([{ kind: 'heading', level: 2, title: 'Title', line: 1 }]);
  });

  it('strips a trailing Quarto attribute block from the title', () => {
    const items = extractOutline(mdState('# Setup and notation {#sec-setup}'), 'md');
    expect(items).toEqual([{ kind: 'heading', level: 1, title: 'Setup and notation', line: 1 }]);
  });

  it('strips the # marks from an ATX heading indented 1-3 spaces', () => {
    const items = extractOutline(mdState('  ## Methods'), 'md');
    expect(items).toEqual([{ kind: 'heading', level: 2, title: 'Methods', line: 1 }]);
  });

  it('strips a trailing Quarto attribute block from a Setext title', () => {
    const doc = ['Setup {#sec-setup}', '=================='].join('\n');
    const items = extractOutline(mdState(doc), 'md');
    expect(items).toEqual([{ kind: 'heading', level: 1, title: 'Setup', line: 1 }]);
  });

  it('captures Setext headings at levels 1 and 2', () => {
    const doc = ['Top Title', '=========', '', 'Second', '------', '', 'body'].join('\n');
    const items = extractOutline(mdState(doc), 'md');
    expect(items).toEqual([
      { kind: 'heading', level: 1, title: 'Top Title', line: 1 },
      { kind: 'heading', level: 2, title: 'Second', line: 4 },
    ]);
  });

  it('returns nothing for a doc with no structure', () => {
    expect(extractOutline(mdState('just a paragraph'), 'md')).toEqual([]);
  });
});

describe('extractOutline — markdown callouts', () => {
  it('includes numbered callouts with type, number, title, and open line', () => {
    const doc = [
      '# Intro',
      '',
      '::: {#thm-pythagoras name="Pythagoras"}',
      'For a right triangle…',
      ':::',
      '',
      '::: {#def-metric}',
      'A metric is…',
      ':::',
    ].join('\n');
    const items = extractOutline(mdState(doc), 'md');
    expect(items).toEqual([
      { kind: 'heading', level: 1, title: 'Intro', line: 1 },
      { kind: 'callout', level: 0, title: 'Pythagoras', line: 3, calloutType: 'theorem', number: 1 },
      { kind: 'callout', level: 0, title: '', line: 7, calloutType: 'definition', number: 1 },
    ]);
  });

  it('excludes unnumbered callouts (proof, remark, admonitions)', () => {
    const doc = [
      '::: {#prf-x}',
      'proof body',
      ':::',
      '::: {.proof}',
      'proof body',
      ':::',
      '::: {.callout-note}',
      'note body',
      ':::',
    ].join('\n');
    expect(extractOutline(mdState(doc), 'md')).toEqual([]);
  });

  it('excludes a callout fence shown inside a code block', () => {
    const doc = ['```', '::: {#thm-sample}', 'x', ':::', '```'].join('\n');
    expect(extractOutline(mdState(doc), 'md')).toEqual([]);
  });
});

describe('extractOutline — markdown figures', () => {
  it('includes standalone images with alt-text title and figure ordinal', () => {
    const doc = [
      '# Plots',
      '',
      '![Residual geometry](figures/residuals.png)',
      '',
      'text',
      '',
      '![](figures/convergence.png)',
    ].join('\n');
    const items = extractOutline(mdState(doc), 'md');
    expect(items).toEqual([
      { kind: 'heading', level: 1, title: 'Plots', line: 1 },
      { kind: 'figure', level: 0, title: 'Residual geometry', line: 3, number: 1 },
      { kind: 'figure', level: 0, title: 'convergence', line: 7, number: 2 },
    ]);
  });

  it('lists a figure div once, as its callout, and numbers bare images apart', () => {
    const doc = [
      '::: {#fig-plot}',
      '![](plot.png)',
      '',
      'The plot',
      ':::',
      '',
      '![Later](later.png)',
    ].join('\n');
    expect(extractOutline(mdState(doc), 'md')).toEqual([
      { kind: 'callout', level: 0, title: '', line: 1, calloutType: 'figure', number: 1 },
      { kind: 'figure', level: 0, title: 'Later', line: 7, number: 1 },
    ]);
  });

  it('excludes inline images inside a paragraph', () => {
    const doc = 'see the ![icon](icon.png) inline';
    expect(extractOutline(mdState(doc), 'md')).toEqual([]);
  });

  it('excludes image syntax inside a code fence', () => {
    const doc = ['```', '![Alt](p.png)', '```'].join('\n');
    expect(extractOutline(mdState(doc), 'md')).toEqual([]);
  });
});

describe('extractOutline — tex sections', () => {
  it('captures sectioning commands with the right depth', () => {
    const doc = [
      '\\section{Intro}',
      'text',
      '\\subsection{Background}',
      '\\subsubsection{Detail}',
      '\\section{Method}',
    ].join('\n');
    const items = extractOutline(texState(doc), 'tex');
    expect(items).toEqual([
      { kind: 'heading', level: 3, title: 'Intro', line: 1 },
      { kind: 'heading', level: 4, title: 'Background', line: 3 },
      { kind: 'heading', level: 5, title: 'Detail', line: 4 },
      { kind: 'heading', level: 3, title: 'Method', line: 5 },
    ]);
  });

  it('handles starred variants and nested braces in titles', () => {
    const doc = '\\section*{Foo \\textbf{bar}}';
    const items = extractOutline(texState(doc), 'tex');
    expect(items).toEqual([{ kind: 'heading', level: 3, title: 'Foo \\textbf{bar}', line: 1 }]);
  });

  it('maps part/chapter/paragraph to their depths', () => {
    const doc = ['\\part{P}', '\\chapter{C}', '\\paragraph{Pg}'].join('\n');
    const items = extractOutline(texState(doc), 'tex');
    expect(items.map((i) => i.level)).toEqual([1, 2, 6]);
  });

  it('captures the optional short-title form \\section[short]{Title}', () => {
    const doc = [
      '\\section[Results]{Empirical results and robustness}',
      '\\subsection*[x]{Starred with optional}',
    ].join('\n');
    const items = extractOutline(texState(doc), 'tex');
    expect(items).toEqual([
      { kind: 'heading', level: 3, title: 'Empirical results and robustness', line: 1 },
      { kind: 'heading', level: 4, title: 'Starred with optional', line: 2 },
    ]);
  });

  it('skips sections quoted in verbatim-family and comment environments', () => {
    const doc = [
      '\\begin{verbatim}',
      '\\section{Quoted}',
      '\\end{verbatim}',
      '\\begin{lstlisting}[language=TeX]',
      '\\section{Listing ghost}',
      '\\end{lstlisting}',
      '\\begin{comment}',
      '\\section{Commented out}',
      '\\end{comment}',
      '\\section{Real}',
    ].join('\n');
    const items = extractOutline(texState(doc), 'tex');
    expect(items).toEqual([{ kind: 'heading', level: 3, title: 'Real', line: 10 }]);
  });

  it('skips sections inside single-line macro definition bodies', () => {
    const doc = [
      '\\newcommand{\\mysec}[1]{\\section*{#1}}',
      '\\renewcommand{\\other}{\\subsection{x}}',
      '\\section{Real}',
    ].join('\n');
    const items = extractOutline(texState(doc), 'tex');
    expect(items).toEqual([{ kind: 'heading', level: 3, title: 'Real', line: 3 }]);
  });

  it('skips sections in % comments, full-line and mid-line', () => {
    const doc = [
      '% \\section{Ghost}',
      'text % \\section{Also ghost}',
      '\\section{Real}',
      'escaped \\% \\section{Not a comment}',
    ].join('\n');
    const items = extractOutline(texState(doc), 'tex');
    expect(items).toEqual([
      { kind: 'heading', level: 3, title: 'Real', line: 3 },
      { kind: 'heading', level: 3, title: 'Not a comment', line: 4 },
    ]);
  });
});

describe('extractOutline — tex callouts', () => {
  it('includes numbered environments with title and per-type number', () => {
    const doc = [
      '\\begin{theorem}[Pythagoras]',
      'a^2 + b^2 = c^2',
      '\\end{theorem}',
      '\\begin{definition}',
      'A metric is…',
      '\\end{definition}',
      '\\begin{theorem}',
      'second',
      '\\end{theorem}',
    ].join('\n');
    const items = extractOutline(texState(doc), 'tex');
    expect(items).toEqual([
      { kind: 'callout', level: 0, title: 'Pythagoras', line: 1, calloutType: 'theorem', number: 1 },
      { kind: 'callout', level: 0, title: '', line: 4, calloutType: 'definition', number: 1 },
      { kind: 'callout', level: 0, title: '', line: 7, calloutType: 'theorem', number: 2 },
    ]);
  });

  it('excludes starred (unnumbered) environments and proofs', () => {
    const doc = [
      '\\begin{theorem*}',
      'x',
      '\\end{theorem*}',
      '\\begin{proof}',
      'y',
      '\\end{proof}',
    ].join('\n');
    expect(extractOutline(texState(doc), 'tex')).toEqual([]);
  });

  it('excludes an unclosed environment', () => {
    const doc = ['\\begin{theorem}', 'still typing…'].join('\n');
    expect(extractOutline(texState(doc), 'tex')).toEqual([]);
  });
});

describe('extractOutline — tex figures', () => {
  it('a table box adds no outline entry', () => {
    const doc = ['\\begin{table}[h]', '  \\caption{Moments}', '\\end{table}'].join('\n');
    expect(extractOutline(texState(doc), 'tex')).toEqual([]);
  });

  it('uses the first caption as the title', () => {
    const doc = [
      '\\begin{figure}[htbp]',
      '  \\includegraphics[width=0.8\\textwidth]{plots/residuals.pdf}',
      '  \\caption{Residual geometry}',
      '\\end{figure}',
    ].join('\n');
    const items = extractOutline(texState(doc), 'tex');
    expect(items).toEqual([
      { kind: 'figure', level: 0, title: 'Residual geometry', line: 1, number: 1 },
    ]);
  });

  it('falls back to the includegraphics basename, then to "Figure"', () => {
    const doc = [
      '\\begin{figure}',
      '  \\includegraphics{plots/convergence.pdf}',
      '\\end{figure}',
      '\\begin{figure*}',
      '  (tikz only)',
      '\\end{figure*}',
    ].join('\n');
    const items = extractOutline(texState(doc), 'tex');
    expect(items).toEqual([
      { kind: 'figure', level: 0, title: 'convergence', line: 1, number: 1 },
      { kind: 'figure', level: 0, title: 'Figure', line: 4, number: 2 },
    ]);
  });

  it('ignores commented-out figures and captions', () => {
    const doc = [
      '% \\begin{figure}',
      '\\begin{figure}',
      '  % \\caption{Ghost caption}',
      '  \\caption{Real caption}',
      '\\end{figure}',
    ].join('\n');
    const items = extractOutline(texState(doc), 'tex');
    expect(items).toEqual([
      { kind: 'figure', level: 0, title: 'Real caption', line: 2, number: 1 },
    ]);
  });

  it('handles a single-line figure environment without desyncing later figures', () => {
    const doc = [
      '\\begin{figure}\\includegraphics{plots/a.png}\\end{figure}',
      'text',
      '\\begin{figure}',
      '  \\caption{Convergence}',
      '\\end{figure}',
    ].join('\n');
    const items = extractOutline(texState(doc), 'tex');
    expect(items).toEqual([
      { kind: 'figure', level: 0, title: 'a', line: 1, number: 1 },
      { kind: 'figure', level: 0, title: 'Convergence', line: 3, number: 2 },
    ]);
  });

  it('reads a caption sharing a line with the closing \\end{figure}', () => {
    const doc = ['\\begin{figure}', '  \\caption{Fit}\\end{figure}'].join('\n');
    const items = extractOutline(texState(doc), 'tex');
    expect(items).toEqual([{ kind: 'figure', level: 0, title: 'Fit', line: 1, number: 1 }]);
  });

  it('excludes an unclosed figure environment', () => {
    const doc = ['\\begin{figure}', '  \\caption{Half-typed}'].join('\n');
    expect(extractOutline(texState(doc), 'tex')).toEqual([]);
  });

  it('caches the scan per Text identity', () => {
    const doc = texState('\\begin{figure}\n\\caption{X}\n\\end{figure}').doc;
    expect(scanTexFigures(doc)).toBe(scanTexFigures(doc));
    const other = texState('\\begin{figure}\n\\caption{X}\n\\end{figure}').doc;
    expect(scanTexFigures(other)).not.toBe(scanTexFigures(doc));
  });
});

describe('extractOutline — ordering', () => {
  it('merges headings, callouts, and figures sorted by line', () => {
    const doc = [
      '\\section{Setup}',
      '\\begin{definition}',
      'd',
      '\\end{definition}',
      '\\section{Results}',
      '\\begin{figure}',
      '\\caption{Fit}',
      '\\end{figure}',
      '\\begin{theorem}[Main]',
      't',
      '\\end{theorem}',
    ].join('\n');
    const items = extractOutline(texState(doc), 'tex');
    expect(items.map((i) => [i.kind, i.line])).toEqual([
      ['heading', 1],
      ['callout', 2],
      ['heading', 5],
      ['figure', 6],
      ['callout', 9],
    ]);
  });
});

describe('extractOutline — caching', () => {
  it('reuses the outline for a selection-only change and recomputes after an edit', () => {
    const state = mdState('# A\n\ntext\n\n## B');
    const items = extractOutline(state, 'md');
    const moved = state.update({ selection: { anchor: 5 } }).state;
    expect(extractOutline(moved, 'md')).toBe(items);
    const edited = moved.update({ changes: { from: moved.doc.length, insert: ' more' } }).state;
    ensureSyntaxTree(edited, edited.doc.length, 5000);
    const next = extractOutline(edited, 'md');
    expect(next).not.toBe(items);
    expect(next.map((i) => i.title)).toEqual(['A', 'B more']);
  });

  it('keys on the language', () => {
    const state = mdState('# A\n\n\\section{S}');
    expect(extractOutline(state, 'md').map((i) => i.title)).toEqual(['A']);
    expect(extractOutline(state, 'tex').map((i) => i.title)).toEqual(['S']);
  });
});
