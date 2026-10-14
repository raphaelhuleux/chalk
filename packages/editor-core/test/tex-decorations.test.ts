import { describe, it, expect } from 'vitest';
import { scanTexStyleRegions } from '../src/editor/tex-style-incremental';
import { scanMathRegions } from '../src/editor/tex-math';

/** Slice out the argument spans the scanner found, for readable assertions. */
function spans(text: string) {
  return scanTexStyleRegions(text, scanMathRegions(text)).map((r) => ({
    kind: r.kind,
    text: text.slice(r.from, r.to),
  }));
}

describe('scanTexStyleRegions', () => {
  it('finds nothing in plain prose', () => {
    expect(scanTexStyleRegions('Just some text.', [])).toEqual([]);
  });

  it('maps sectioning commands to heading levels', () => {
    expect(spans('\\section{Intro}')).toEqual([{ kind: 'h1', text: 'Intro' }]);
    expect(spans('\\subsection{Details}')).toEqual([{ kind: 'h2', text: 'Details' }]);
    expect(spans('\\subsubsection{Fine}')).toEqual([{ kind: 'h3', text: 'Fine' }]);
  });

  it('accepts the starred section forms', () => {
    expect(spans('\\section*{Unnumbered}')).toEqual([{ kind: 'h1', text: 'Unnumbered' }]);
  });

  it('does not confuse \\section with \\subsection or \\subsubsection', () => {
    const s = spans('\\subsubsection{a}\n\\subsection{b}\n\\section{c}');
    expect(s).toEqual([
      { kind: 'h3', text: 'a' },
      { kind: 'h2', text: 'b' },
      { kind: 'h1', text: 'c' },
    ]);
  });

  it('styles inline text commands', () => {
    expect(spans('\\textbf{bold}')).toEqual([{ kind: 'strong', text: 'bold' }]);
    expect(spans('\\emph{it}')).toEqual([{ kind: 'em', text: 'it' }]);
    expect(spans('\\textit{it2}')).toEqual([{ kind: 'em', text: 'it2' }]);
    expect(spans('\\texttt{mono}')).toEqual([{ kind: 'tt', text: 'mono' }]);
  });

  it('handles nested commands, emitting both marks', () => {
    const s = spans('\\textbf{\\emph{x}}');
    expect(s).toContainEqual({ kind: 'strong', text: '\\emph{x}' });
    expect(s).toContainEqual({ kind: 'em', text: 'x' });
  });

  it('reads brace-balanced arguments (nested groups)', () => {
    expect(spans('\\textbf{a {b} c}')).toEqual([{ kind: 'strong', text: 'a {b} c' }]);
  });

  it('reads multi-line arguments', () => {
    expect(spans('\\textbf{line one\nline two}')).toEqual([
      { kind: 'strong', text: 'line one\nline two' },
    ]);
  });

  it('ignores commands inside math regions', () => {
    // \text{...} inside display math must not be styled.
    expect(spans('\\[ \\textbf{x} \\]')).toEqual([]);
    expect(spans('before $\\emph{y}$ after')).toEqual([]);
  });

  it('still styles commands outside a neighbouring math region', () => {
    const s = spans('\\section{Title}\n\\[a+b\\]\n\\textbf{note}');
    expect(s).toEqual([
      { kind: 'h1', text: 'Title' },
      { kind: 'strong', text: 'note' },
    ]);
  });

  it('ignores commands in a % line comment', () => {
    expect(spans('% \\section{nope}\n\\section{yes}')).toEqual([
      { kind: 'h1', text: 'yes' },
    ]);
  });

  it('does not match an unterminated argument', () => {
    expect(scanTexStyleRegions('\\textbf{oops', [])).toEqual([]);
  });

  it('does not match look-alike commands', () => {
    expect(scanTexStyleRegions('\\sectioneer{x}', [])).toEqual([]);
    expect(scanTexStyleRegions('\\section', [])).toEqual([]);
  });

  it('records the full command extent and name (cmdFrom → to)', () => {
    const text = 'pre \\emph{word} post';
    const [r] = scanTexStyleRegions(text, []);
    expect(text.slice(r.cmdFrom, r.to + 1)).toBe('\\emph{word}');
    expect(r.name).toBe('emph');
    expect(r.starred).toBe(false);
  });

  it('flags starred sectioning commands', () => {
    const [r] = scanTexStyleRegions('\\section*{Unnumbered}', []);
    expect(r.starred).toBe(true);
    expect(r.name).toBe('section');
  });

  it('accepts a short-title optional argument on sectioning commands', () => {
    const text = '\\section[Short]{Long Title}';
    const [r] = scanTexStyleRegions(text, []);
    expect(r.kind).toBe('h1');
    expect(text.slice(r.from, r.to)).toBe('Long Title');
    expect(r.cmdFrom).toBe(0);
  });

  it('styles the extra inline commands: underline, small caps, run-in headings', () => {
    expect(spans('\\underline{u}')).toEqual([{ kind: 'underline', text: 'u' }]);
    expect(spans('\\textsc{Caps}')).toEqual([{ kind: 'sc', text: 'Caps' }]);
    expect(spans('\\paragraph{Run-in}')).toEqual([{ kind: 'runin', text: 'Run-in' }]);
    expect(spans('\\subparagraph{Deeper}')).toEqual([{ kind: 'runin', text: 'Deeper' }]);
  });

  it('maps part and chapter to the largest heading', () => {
    expect(spans('\\part{One}')).toEqual([{ kind: 'h1', text: 'One' }]);
    expect(spans('\\chapter{Two}')).toEqual([{ kind: 'h1', text: 'Two' }]);
  });
});

describe('scanTexStyleRegions: refs, cites, labels, footnotes, links', () => {
  it('finds the \\ref family', () => {
    expect(spans('see \\ref{fig:model}')).toEqual([{ kind: 'ref', text: 'fig:model' }]);
    expect(spans('\\eqref{eq:euler}')).toEqual([{ kind: 'ref', text: 'eq:euler' }]);
    expect(spans('\\cref{sec:a}')).toEqual([{ kind: 'ref', text: 'sec:a' }]);
    expect(spans('\\Cref{sec:a}')).toEqual([{ kind: 'ref', text: 'sec:a' }]);
    expect(spans('\\autoref{tab:b}')).toEqual([{ kind: 'ref', text: 'tab:b' }]);
  });

  it('finds the \\cite family, keeping the key group as the argument', () => {
    expect(spans('\\cite{smets2007}')).toEqual([{ kind: 'cite', text: 'smets2007' }]);
    expect(spans('\\citep{a,b}')).toEqual([{ kind: 'cite', text: 'a,b' }]);
    expect(spans('\\citet{a}')).toEqual([{ kind: 'cite', text: 'a' }]);
    expect(spans('\\parencite{a}')).toEqual([{ kind: 'cite', text: 'a' }]);
  });

  it('skips optional arguments on cites and footnotes', () => {
    expect(spans('\\citep[p.~3]{smets2007}')).toEqual([{ kind: 'cite', text: 'smets2007' }]);
    expect(spans('\\citep[see][p.~3]{k}')).toEqual([{ kind: 'cite', text: 'k' }]);
    expect(spans('\\footnote[2]{custom}')).toEqual([{ kind: 'footnote', text: 'custom' }]);
  });

  it('finds \\label', () => {
    const text = '\\section{A}\\label{sec:a}';
    expect(spans(text)).toEqual([
      { kind: 'h1', text: 'A' },
      { kind: 'label', text: 'sec:a' },
    ]);
  });

  it('finds \\footnote and still scans nested commands inside it', () => {
    const s = spans('\\footnote{see \\emph{x}}');
    expect(s).toContainEqual({ kind: 'footnote', text: 'see \\emph{x}' });
    expect(s).toContainEqual({ kind: 'em', text: 'x' });
  });

  it('captures \\href url and text arguments', () => {
    const text = 'go \\href{https://x.y/z}{link text} now';
    const [r] = scanTexStyleRegions(text, []);
    expect(r.kind).toBe('href');
    expect(r.url).toBe('https://x.y/z');
    expect(text.slice(r.from, r.to)).toBe('link text');
    expect(text.slice(r.cmdFrom, r.to + 1)).toBe('\\href{https://x.y/z}{link text}');
  });

  it('captures \\url with the target as both text and url', () => {
    const text = '\\url{https://x.y}';
    const [r] = scanTexStyleRegions(text, []);
    expect(r.kind).toBe('url');
    expect(r.url).toBe('https://x.y');
    expect(text.slice(r.from, r.to)).toBe('https://x.y');
  });

  it('ignores a malformed \\href with no text argument', () => {
    expect(scanTexStyleRegions('\\href{https://x.y}', [])).toEqual([]);
  });

  it('ignores refs inside math regions', () => {
    expect(spans('$x \\ref{eq:a}$')).toEqual([]);
  });

  it('does not match look-alike ref commands', () => {
    expect(scanTexStyleRegions('\\reference{x}', [])).toEqual([]);
    expect(scanTexStyleRegions('\\citation{x}', [])).toEqual([]);
  });
});
