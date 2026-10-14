import { describe, it, expect } from 'vitest';
import { Text } from '@codemirror/state';
import { scanTexFrames, isBeamerDoc } from '../src/editor/tex-frame-plugin';

/**
 * The frame scanner: the pure, document-level half of the slide-card
 * rendering. Everything here is a function of the document text alone, so it
 * is fully testable in jsdom (the geometry half is not — see
 * Tests/browser/run.mjs).
 */

const doc = (s: string): Text => Text.of(s.split('\n'));

/** A minimal beamer preamble, so the gate below doesn't suppress the scan. */
const BEAMER = '\\documentclass{beamer}\n\\begin{document}\n';

describe('scanTexFrames — recognising a frame', () => {
  it('finds a closed frame and reports its fence lines', () => {
    const regions = scanTexFrames(doc(`${BEAMER}\\begin{frame}\nbody\n\\end{frame}`));
    expect(regions).toHaveLength(1);
    expect(regions[0].openLine).toBe(3);
    expect(regions[0].closeLine).toBe(5);
  });

  it('reads the brace-argument title', () => {
    const regions = scanTexFrames(doc(`${BEAMER}\\begin{frame}{Roadmap}\nbody\n\\end{frame}`));
    expect(regions[0].title).toBe('Roadmap');
    expect(regions[0].subtitle).toBeNull();
  });

  it('reads a title and a subtitle', () => {
    const regions = scanTexFrames(
      doc(`${BEAMER}\\begin{frame}{Bayesian updating}{a worked example}\nbody\n\\end{frame}`),
    );
    expect(regions[0].title).toBe('Bayesian updating');
    expect(regions[0].subtitle).toBe('a worked example');
  });

  it('tolerates an option list before the title', () => {
    const regions = scanTexFrames(
      doc(`${BEAMER}\\begin{frame}[fragile,t]{How to}\nbody\n\\end{frame}`),
    );
    expect(regions[0].title).toBe('How to');
  });

  it('tolerates a same-line \\label after the title', () => {
    const regions = scanTexFrames(
      doc(`${BEAMER}\\begin{frame}{Bayes}\\label{frm:bayes}\nbody\n\\end{frame}`),
    );
    expect(regions[0].title).toBe('Bayes');
  });

  it('reports no title for a bare frame', () => {
    const regions = scanTexFrames(doc(`${BEAMER}\\begin{frame}\n\\titlepage\n\\end{frame}`));
    expect(regions[0].title).toBeNull();
    expect(regions[0].titleLine).toBeUndefined();
  });

  it('numbers frames in document order', () => {
    const regions = scanTexFrames(
      doc(
        `${BEAMER}\\begin{frame}{One}\n\\end{frame}\n` +
          `\\begin{frame}{Two}\n\\end{frame}\n` +
          `\\begin{frame}{Three}\n\\end{frame}`,
      ),
    );
    expect(regions.map((r) => r.number)).toEqual([1, 2, 3]);
  });
});

describe('scanTexFrames — the \\frametitle surface syntax', () => {
  it('picks up \\frametitle and \\framesubtitle from inside the region', () => {
    const regions = scanTexFrames(
      doc(
        `${BEAMER}\\begin{frame}[t]\n` +
          `  \\frametitle{Identification}\n` +
          `  \\framesubtitle{three conditions}\n` +
          `  body\n` +
          `\\end{frame}`,
      ),
    );
    expect(regions[0].title).toBe('Identification');
    expect(regions[0].subtitle).toBe('three conditions');
    expect(regions[0].titleLine).toBe(4);
    expect(regions[0].subtitleLine).toBe(5);
  });

  it('prefers the brace-argument title when both forms are present', () => {
    const regions = scanTexFrames(
      doc(`${BEAMER}\\begin{frame}{Brace}\n  \\frametitle{Command}\n\\end{frame}`),
    );
    expect(regions[0].title).toBe('Brace');
    expect(regions[0].titleLine).toBeUndefined();
  });
});

describe('scanTexFrames — traps', () => {
  it('ignores a frame quoted inside verbatim', () => {
    const regions = scanTexFrames(
      doc(
        `${BEAMER}\\begin{frame}[fragile]{Sample}\n` +
          `\\begin{verbatim}\n` +
          `\\begin{frame}{Not real}\n` +
          `\\end{frame}\n` +
          `\\end{verbatim}\n` +
          `\\end{frame}`,
      ),
    );
    expect(regions).toHaveLength(1);
    expect(regions[0].title).toBe('Sample');
    expect(regions[0].closeLine).toBe(8);
  });

  it('ignores a commented-out frame', () => {
    const regions = scanTexFrames(
      doc(`${BEAMER}% \\begin{frame}{Cut}\n% \\end{frame}\n\\begin{frame}{Real}\n\\end{frame}`),
    );
    expect(regions).toHaveLength(1);
    expect(regions[0].title).toBe('Real');
  });

  it('ignores a frame quoted in a macro definition', () => {
    const regions = scanTexFrames(
      doc(`${BEAMER}\\newcommand{\\qf}[1]{\\begin{frame}{#1}\\end{frame}}`),
    );
    expect(regions).toHaveLength(0);
  });

  it('emits nothing for an unclosed frame', () => {
    const regions = scanTexFrames(doc(`${BEAMER}\\begin{frame}{Typing}\nstill going`));
    expect(regions).toHaveLength(0);
  });

  it('does not treat a nested environment close as the frame close', () => {
    const regions = scanTexFrames(
      doc(
        `${BEAMER}\\begin{frame}{Outer}\n` +
          `  \\begin{itemize}\n` +
          `    \\item a\n` +
          `  \\end{itemize}\n` +
          `\\end{frame}`,
      ),
    );
    expect(regions[0].closeLine).toBe(7);
  });

  it('closes an unterminated verbatim with its frame', () => {
    // A \begin{verbatim} the author has not closed yet must not swallow the
    // rest of the file: an unterminated verbatim runs to the frame's end, so
    // the card still closes on its \end{frame} and the frames below it keep
    // rendering.
    const regions = scanTexFrames(
      doc(
        `${BEAMER}\\begin{frame}[fragile]{Sample}\n` +
          `\\begin{verbatim}\n` +
          `still typing\n` +
          `\\end{frame}\n` +
          `\\begin{frame}{Next}\n` +
          `body\n` +
          `\\end{frame}`,
      ),
    );
    expect(regions).toHaveLength(2);
    expect(regions[0].closeLine).toBe(6);
    expect(regions[0].verbatim).toEqual([{ from: 4, to: 6 }]);
    expect(regions[1].openLine).toBe(7);
    expect(regions[1].closeLine).toBe(9);
  });

  it('caches per document identity', () => {
    const d = doc(`${BEAMER}\\begin{frame}{One}\n\\end{frame}`);
    expect(scanTexFrames(d)).toBe(scanTexFrames(d));
  });
});

describe('isBeamerDoc — the gate', () => {
  it('is true for a beamer documentclass', () => {
    expect(isBeamerDoc(doc('\\documentclass[aspectratio=169]{beamer}\n\\begin{frame}'))).toBe(true);
  });

  it('is false for an article that happens to use a frame environment', () => {
    expect(isBeamerDoc(doc('\\documentclass{article}\n\\begin{frame}\n\\end{frame}'))).toBe(false);
  });

  it('is true for a preamble-less fragment containing a frame', () => {
    expect(isBeamerDoc(doc('\\begin{frame}{Chunk}\n\\end{frame}'))).toBe(true);
  });

  it('is false for a preamble-less fragment with no frame at all', () => {
    expect(isBeamerDoc(doc('just some prose\n\\section{Hi}'))).toBe(false);
  });

  it('suppresses the scan entirely when the gate is false', () => {
    const regions = scanTexFrames(
      doc('\\documentclass{article}\n\\begin{frame}\nbody\n\\end{frame}'),
    );
    expect(regions).toHaveLength(0);
  });
});

describe('scan cost', () => {
  it('does not re-scan when the document has not changed', async () => {
    const { __frameScanCount, __resetFrameScanCount } = await import(
      '../src/editor/tex-frame-plugin'
    );
    const d = doc(`${BEAMER}\\begin{frame}{One}\n\\end{frame}`);
    __resetFrameScanCount();
    for (let i = 0; i < 20; i++) scanTexFrames(d);
    expect(__frameScanCount()).toBe(1);
  });

  it('never materialises the document as one string', () => {
    // The gate runs once per document change for EVERY .tex file, so it must
    // not allocate a copy of the whole document per keystroke — the exact cost
    // the shared mathRegionsField exists to avoid (typing-perf.test.ts).
    let toStringCalls = 0;
    const big = Text.of([
      '\\documentclass{article}',
      ...Array.from({ length: 5000 }, (_, i) => `prose line ${i}`),
    ]);
    const counting = new Proxy(big, {
      get(target, prop, receiver) {
        if (prop === 'toString') {
          toStringCalls++;
          return () => target.toString();
        }
        const value = Reflect.get(target, prop, receiver);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    }) as Text;

    expect(isBeamerDoc(counting)).toBe(false);
    expect(toStringCalls).toBe(0);
  });

  it('runs the documentclass regex only on lines that could carry one', async () => {
    // The gate walks every line of any .tex file that has no `\documentclass`
    // near the top -- a fragment, an \input-ed chapter, a scratch file -- on
    // every keystroke, because its cache is keyed on the immutable `Text`.
    // A regex execution per line made that walk 4.1% of tex keystroke script
    // time in the bundle profile (2026-08-26). A plain substring reject is a
    // strict superset of what the regex can match, so it costs nothing in
    // correctness: the regex is anchored on the same literal.
    const { __documentclassProbeCount, __resetDocumentclassProbeCount } = await import(
      '../src/editor/tex-frame-plugin'
    );
    const prose = Text.of(Array.from({ length: 5000 }, (_, i) => `prose line ${i}`));
    __resetDocumentclassProbeCount();
    expect(isBeamerDoc(prose)).toBe(false);
    expect(__documentclassProbeCount()).toBe(0);
  });

  it('still reads a documentclass that sits below prose', async () => {
    const { __documentclassProbeCount, __resetDocumentclassProbeCount } = await import(
      '../src/editor/tex-frame-plugin'
    );
    const d = doc('% a note\n\n\\documentclass[t]{beamer}\n\\begin{document}');
    __resetDocumentclassProbeCount();
    expect(isBeamerDoc(d)).toBe(true);
    expect(__documentclassProbeCount()).toBe(1);
  });

  it('does not mistake a longer command for documentclass', () => {
    // `\documentclassname` contains the literal the reject tests for, so the
    // reject must hand off to the regex rather than answer on its own.
    expect(isBeamerDoc(doc('\\documentclassname{beamer}\n\\section{Hi}'))).toBe(false);
  });
});
