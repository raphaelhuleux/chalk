import { describe, it, expect } from 'vitest';
import { Text } from '@codemirror/state';
import {
  fenceTikzDocument,
  keepPreamble,
  localizeError,
  scanTexPictures,
  texPreamble,
  tikzDocument,
} from '../src/editor/tikz-source';

/** The standalone document the host typesets: what is kept, what is dropped. */

const doc = (s: string) => Text.of(s.split('\n'));

describe('keepPreamble', () => {
  it('keeps what a figure can use and drops page setup', () => {
    const kept = keepPreamble(
      [
        '\\documentclass[11pt]{beamer}',
        '\\usetheme{metropolis}',
        '\\usepackage{amsmath,hyperref} % refs',
        '\\usepackage[margin=1in]{geometry}',
        '\\usetikzlibrary{arrows.meta}',
        '\\title{Talk}',
        '\\newcommand{\\R}{\\mathbb{R}}',
      ].join('\n'),
    );
    expect(kept.split('\n')).toEqual([
      '\\usepackage{amsmath} ',
      '\\usetikzlibrary{arrows.meta}',
      '\\newcommand{\\R}{\\mathbb{R}}',
    ]);
  });

  it('keeps a multi-line statement whole', () => {
    const kept = keepPreamble('\\tikzset{\n  dot/.style={circle, fill}, % a dot\n}\n\\author{Me}');
    expect(kept).toBe('\\tikzset{\n  dot/.style={circle, fill}, \n}');
  });

  it('carries the font size of the document class', () => {
    expect(texPreamble('\\documentclass[12pt,a4paper]{article}\n').classOptions).toEqual(['12pt']);
  });
});

describe('scanTexPictures', () => {
  it('finds top-level pictures in the body, nested ones inside them', () => {
    const text = [
      '\\documentclass{article}',
      '\\newcommand{\\pic}{\\begin{tikzpicture}\\end{tikzpicture}}',
      '\\begin{document}',
      '\\begin{tikzpicture}',
      '  \\node {\\begin{tikzpicture}\\draw (0,0) -- (1,1);\\end{tikzpicture}};',
      '\\end{tikzpicture}',
      '% \\begin{tikzcd} commented out',
      '\\begin{verbatim}',
      '\\begin{tikzpicture}',
      '\\end{verbatim}',
      '\\begin{tikzcd} A \\arrow[r] & B \\end{tikzcd}',
      '\\begin{tikzpicture} unclosed',
      '\\end{document}',
    ].join('\n');
    const d = doc(text);
    const { pictures, bodyStart } = scanTexPictures(d);
    expect(bodyStart).toBe(text.indexOf('\\begin{document}'));
    expect(pictures.map((p) => d.sliceString(p.from, p.to).split('\n')[0])).toEqual([
      '\\begin{tikzpicture}',
      '\\begin{tikzcd} A \\arrow[r] & B \\end{tikzcd}',
    ]);
    expect(pictures.map((p) => p.endLine)).toEqual([6, 11]);
  });

  it('scans a chapter file with no preamble from the top', () => {
    const { pictures, bodyStart } = scanTexPictures(doc('\\begin{tikzpicture}\n\\end{tikzpicture}'));
    expect(bodyStart).toBe(-1);
    expect(pictures).toHaveLength(1);
  });
});

describe('fenceTikzDocument', () => {
  it('wraps bare drawing commands, after leading package lines', () => {
    const out = fenceTikzDocument('\\usetikzlibrary{calc}\n\\draw (0,0) -- (1,1);');
    expect(out).toContain('\\usepackage{tikz}\n\\usepackage{amsmath,amssymb}\n\\usetikzlibrary{calc}\n\\begin{document}');
    expect(out).toContain('\\begin{tikzpicture}\n\\draw (0,0) -- (1,1);\n\\end{tikzpicture}');
  });

  it('splits a whole document at \\begin{document} (the TikZJax spelling)', () => {
    const out = fenceTikzDocument(
      '\\usepackage{pgfplots}\n\\begin{document}\n\\begin{tikzpicture}\\end{tikzpicture}\n\\end{document}',
    );
    expect(out.match(/\\begin\{document\}/g)).toHaveLength(1);
    expect(out).toContain('\\usepackage{pgfplots}');
    // Named already, so not implied again.
    expect(out).not.toContain('compat=newest');
  });

  it('adds the packages the picture implies and skips chunk options', () => {
    const out = fenceTikzDocument('#| echo: false\n\\begin{tikzcd} A \\arrow[r] & B \\end{tikzcd}');
    expect(out).not.toContain('#|');
    expect(out).toContain('\\usepackage{tikz-cd}');
    expect(fenceTikzDocument('\\begin{tikzpicture}\\begin{axis}\\end{axis}\\end{tikzpicture}')).toContain(
      '\\pgfplotsset{compat=newest}',
    );
  });
});

describe('tikzDocument', () => {
  it('falls back to the math packages without a preamble, and loads tikz first', () => {
    expect(tikzDocument('BODY', null)).toBe(
      [
        '\\documentclass[border=2pt]{standalone}',
        '\\usepackage{tikz}',
        '\\usepackage{amsmath,amssymb}',
        '\\begin{document}',
        'BODY',
        '\\end{document}',
        '',
      ].join('\n'),
    );
  });

  it('keeps an empty kept preamble empty', () => {
    const out = tikzDocument('BODY', { preamble: '', classOptions: ['11pt'] });
    expect(out.startsWith('\\documentclass[border=2pt,11pt]{standalone}\n\\usepackage{tikz}\n\\begin{document}')).toBe(true);
  });

  it("leaves tikz to a preamble that loads it, so the user's options don't clash", () => {
    for (const line of ['\\usepackage[dvipsnames]{tikz}', '\\usepackage{amsmath,pgfplots}']) {
      const out = tikzDocument('BODY', { preamble: `${line}\n\\usetikzlibrary{calc}`, classOptions: [] });
      expect(out).not.toContain('\\usepackage{tikz}');
      expect(out).toContain(line);
    }
  });
});

describe('localizeError', () => {
  const document = tikzDocument('\\begin{tikzpicture}\n\\drwa (0,0);\n\\end{tikzpicture}', null);
  const error = '! Undefined control sequence.\nl.6 \\drwa';

  it("maps TeX's line in the generated document to the user's", () => {
    // Body line 1 is document line 5, so l.6 is the picture's second line.
    expect(localizeError(error, document, 40)).toBe('! Undefined control sequence.\nline 41: \\drwa');
  });

  it('drops the number when the first line is unknown', () => {
    expect(localizeError(error, document, null)).toBe('! Undefined control sequence.\n\\drwa');
  });
});
