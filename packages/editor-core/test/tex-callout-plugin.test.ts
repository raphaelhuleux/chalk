import { describe, it, expect } from 'vitest';
import { Text } from '@codemirror/state';
import {
  parseTexEnvOpen,
  isTexEnvClose,
  scanTexCallouts,
} from '../src/editor/tex-callout-plugin';
import { closingFenceHideRange } from '../src/editor/callout-core';

const doc = (s: string): Text => Text.of(s.split('\n'));

describe('parseTexEnvOpen', () => {
  it('recognises a bare env and maps it to a label', () => {
    expect(parseTexEnvOpen('\\begin{theorem}')).toMatchObject({
      type: 'theorem',
      label: 'Theorem',
      title: null,
      numbered: true,
    });
  });

  it('extracts an optional-argument title', () => {
    expect(parseTexEnvOpen('\\begin{theorem}[Pythagoras]')).toMatchObject({
      label: 'Theorem',
      title: 'Pythagoras',
    });
  });

  it('tolerates a trailing \\label on the begin line (title + label)', () => {
    expect(parseTexEnvOpen('\\begin{theorem}[Pythagoras]\\label{thm:pythagoras}')).toMatchObject({
      type: 'theorem',
      title: 'Pythagoras',
      numbered: true,
    });
  });

  it('tolerates a trailing \\label with no title', () => {
    expect(parseTexEnvOpen('\\begin{proof}\\label{prf:pythagoras}')).toMatchObject({
      type: 'proof',
      numbered: false,
    });
    expect(parseTexEnvOpen('\\begin{definition}[Martingale]\\label{def:martingale}')?.label).toBe(
      'Definition',
    );
  });

  it('maps definition and the rest of the family', () => {
    expect(parseTexEnvOpen('\\begin{definition}')?.label).toBe('Definition');
    expect(parseTexEnvOpen('\\begin{lemma}')?.label).toBe('Lemma');
    expect(parseTexEnvOpen('\\begin{corollary}')?.label).toBe('Corollary');
    expect(parseTexEnvOpen('\\begin{proposition}')?.label).toBe('Proposition');
    expect(parseTexEnvOpen('\\begin{example}')?.label).toBe('Example');
  });

  it('recognises assumption as a numbered callout', () => {
    expect(parseTexEnvOpen('\\begin{assumption}[Rational expectations]')).toMatchObject({
      type: 'assumption',
      label: 'Assumption',
      title: 'Rational expectations',
      numbered: true,
    });
  });

  it('marks proof and remark as unnumbered', () => {
    expect(parseTexEnvOpen('\\begin{proof}')?.numbered).toBe(false);
    expect(parseTexEnvOpen('\\begin{remark}')?.numbered).toBe(false);
  });

  it('treats a starred environment as unnumbered', () => {
    expect(parseTexEnvOpen('\\begin{theorem*}')).toMatchObject({
      type: 'theorem',
      label: 'Theorem',
      numbered: false,
    });
  });

  it('ignores unrecognised environments', () => {
    expect(parseTexEnvOpen('\\begin{equation}')).toBeNull();
    expect(parseTexEnvOpen('\\begin{itemize}')).toBeNull();
    expect(parseTexEnvOpen('\\begin{bogus}')).toBeNull();
  });

  it('ignores lines that are not a lone begin', () => {
    expect(parseTexEnvOpen('text \\begin{theorem}')).toBeNull();
    expect(parseTexEnvOpen('\\begin{theorem} body here')).toBeNull();
  });

  it('tolerates leading whitespace', () => {
    expect(parseTexEnvOpen('  \\begin{lemma}')?.label).toBe('Lemma');
  });
});

describe('isTexEnvClose', () => {
  it('matches the matching end', () => {
    expect(isTexEnvClose('\\end{theorem}', 'theorem')).toBe(true);
    expect(isTexEnvClose('  \\end{theorem}  ', 'theorem')).toBe(true);
  });

  it('does not match a different env', () => {
    expect(isTexEnvClose('\\end{proof}', 'theorem')).toBe(false);
  });

  it('does not match ordinary text', () => {
    expect(isTexEnvClose('the end \\end{theorem} of', 'theorem')).toBe(false);
  });
});

describe('scanTexCallouts', () => {
  it('finds a single closed region with its line span', () => {
    const regions = scanTexCallouts(doc('\\begin{theorem}\nbody\n\\end{theorem}'));
    expect(regions).toHaveLength(1);
    expect(regions[0]).toMatchObject({
      type: 'theorem',
      number: 1,
      openLine: 1,
      closeLine: 3,
    });
  });

  it('numbers per type in document order', () => {
    const src = [
      '\\begin{theorem}',
      'a',
      '\\end{theorem}',
      '',
      '\\begin{definition}',
      'b',
      '\\end{definition}',
      '',
      '\\begin{theorem}',
      'c',
      '\\end{theorem}',
    ].join('\n');
    const nums = scanTexCallouts(doc(src)).map((r) => `${r.type}${r.number}`);
    expect(nums).toEqual(['theorem1', 'definition1', 'theorem2']);
  });

  it('does not number proof / remark / starred', () => {
    expect(scanTexCallouts(doc('\\begin{proof}\nqed\n\\end{proof}'))[0].number).toBeUndefined();
    expect(
      scanTexCallouts(doc('\\begin{theorem*}\nx\n\\end{theorem*}'))[0].number,
    ).toBeUndefined();
  });

  it('closes only on the matching end, ignoring an inner mismatched end', () => {
    // A nested proof inside a theorem: the inner \end{proof} must NOT close
    // the theorem; only \end{theorem} does (non-nested v1 — the whole span
    // becomes one theorem box).
    const src = '\\begin{theorem}\n\\begin{proof}\nx\n\\end{proof}\n\\end{theorem}';
    const regions = scanTexCallouts(doc(src));
    expect(regions).toHaveLength(1);
    expect(regions[0]).toMatchObject({ type: 'theorem', openLine: 1, closeLine: 5 });
  });

  it('ignores an unterminated block (renders nothing until closed)', () => {
    expect(scanTexCallouts(doc('\\begin{theorem}\nstill typing'))).toHaveLength(0);
  });

  it('keeps blank lines inside the body within the region span', () => {
    const regions = scanTexCallouts(doc('\\begin{theorem}\nline 1\n\nline 2\n\\end{theorem}'));
    expect(regions[0]).toMatchObject({ openLine: 1, closeLine: 5 });
  });
});

describe('closingFenceHideRange (shared)', () => {
  it('covers the newline before the fence, not just the fence text', () => {
    const src = '\\begin{theorem}\nbody\n\\end{theorem}';
    const d = doc(src);
    const r = scanTexCallouts(d)[0];
    const range = closingFenceHideRange(d, r);
    expect(range.from).toBe(d.line(2).to);
    expect(range.to).toBe(d.line(3).to);
    expect(range.from).toBeLessThan(d.line(3).from);
  });
});

describe('float environments box like callouts', () => {
  // `\begin{figure}`/`\begin{table}` render as a numbered card, counted per
  // type like LaTeX. Their `[…]` is float placement, never a title, and the
  // starred two-column form is still numbered.
  it('figure and table are numbered callouts with no title', () => {
    expect(parseTexEnvOpen('\\begin{figure}[!htbp]')).toMatchObject({
      type: 'figure',
      label: 'Figure',
      title: null,
      numbered: true,
    });
    expect(parseTexEnvOpen('\\begin{table}')).toMatchObject({ type: 'table', label: 'Table', numbered: true });
    expect(parseTexEnvOpen('\\begin{figure*}[t]')).toMatchObject({ type: 'figure', numbered: true });
  });

  it('still recognises the theorem family', () => {
    expect(parseTexEnvOpen('\\begin{theorem}')).toMatchObject({ type: 'theorem' });
  });
});
