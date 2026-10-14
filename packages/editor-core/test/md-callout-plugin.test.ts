import { describe, it, expect } from 'vitest';
import { Text } from '@codemirror/state';
import { parseFenceOpen, isFenceClose, scanCallouts } from '../src/editor/md-callout-plugin';
import { closingFenceHideRange } from '../src/editor/callout-core';

const doc = (s: string): Text => Text.of(s.split('\n'));

describe('parseFenceOpen', () => {
  it('recognises a numbered block by its #prefix- ID', () => {
    expect(parseFenceOpen('::: {#thm-pythagoras}')).toMatchObject({
      type: 'theorem',
      label: 'Theorem',
      title: null,
      numbered: true,
    });
  });

  it('maps every numbered prefix to its environment', () => {
    const cases: Array<[string, string]> = [
      ['thm', 'Theorem'],
      ['lem', 'Lemma'],
      ['cor', 'Corollary'],
      ['prp', 'Proposition'],
      ['cnj', 'Conjecture'],
      ['def', 'Definition'],
      ['exm', 'Example'],
      ['exr', 'Exercise'],
    ];
    for (const [prefix, label] of cases) {
      const parsed = parseFenceOpen(`::: {#${prefix}-x}`);
      expect(parsed).toMatchObject({ label, numbered: true });
    }
  });

  it('extracts a double-quoted name as the title', () => {
    expect(parseFenceOpen('::: {#thm-pythagoras name="Pythagoras"}')).toMatchObject({
      label: 'Theorem',
      title: 'Pythagoras',
    });
  });

  it('extracts a single-quoted name', () => {
    expect(parseFenceOpen("::: {#def-group name='Group'}")?.title).toBe('Group');
  });

  it('recognises unnumbered blocks by class', () => {
    expect(parseFenceOpen('::: {.proof}')).toMatchObject({ type: 'proof', numbered: false });
    expect(parseFenceOpen('::: {.remark}')).toMatchObject({ type: 'remark', numbered: false });
    expect(parseFenceOpen('::: {.solution}')).toMatchObject({ type: 'solution', numbered: false });
  });

  it('keeps rendering an unnumbered block that also carries ref=', () => {
    expect(parseFenceOpen('::: {.proof ref="thm-pythagoras"}')).toMatchObject({
      type: 'proof',
      numbered: false,
    });
  });

  it('ignores the old class-based numbered syntax (not valid Quarto)', () => {
    expect(parseFenceOpen('::: {.theorem}')).toBeNull();
    expect(parseFenceOpen('::: {.lemma}')).toBeNull();
    expect(parseFenceOpen('::: {.definition title="Group"}')).toBeNull();
  });

  it('ignores unrecognised IDs and classes', () => {
    expect(parseFenceOpen('::: {#foo-bar}')).toBeNull();
    expect(parseFenceOpen('::: {#thm}')).toBeNull(); // prefix needs a -label
    expect(parseFenceOpen('::: {.bogus}')).toBeNull();
    expect(parseFenceOpen(':::')).toBeNull();
  });

  it('recognises proof-like blocks by their #prefix- ID (unnumbered, referenceable)', () => {
    expect(parseFenceOpen('::: {#prf-pythagoras}')).toMatchObject({
      type: 'proof',
      label: 'Proof',
      numbered: false,
      refId: 'prf-pythagoras',
    });
    expect(parseFenceOpen('::: {#sol-check}')).toMatchObject({ type: 'solution', refId: 'sol-check' });
    expect(parseFenceOpen('::: {#rem-scope}')).toMatchObject({ type: 'remark', refId: 'rem-scope' });
  });

  it('captures the refId slug on a numbered block', () => {
    expect(parseFenceOpen('::: {#thm-pythagoras}')?.refId).toBe('thm-pythagoras');
  });

  it('recognises Quarto admonitions by class (unnumbered)', () => {
    const cases: Array<[string, string]> = [
      ['note', 'Note'],
      ['tip', 'Tip'],
      ['warning', 'Warning'],
      ['important', 'Important'],
      ['caution', 'Caution'],
    ];
    for (const [type, label] of cases) {
      expect(parseFenceOpen(`::: {.callout-${type}}`)).toMatchObject({ type, label, numbered: false });
    }
  });

  it('reads a title= attribute as the title', () => {
    expect(parseFenceOpen('::: {.callout-note title="Heads up"}')?.title).toBe('Heads up');
  });
});

describe('heading-title enrichment', () => {
  it('lifts a leading ## heading into the region title and marks its line', () => {
    const regions = scanCallouts(doc('::: {#thm-x}\n## Pythagorean Theorem\n\nbody\n:::'));
    expect(regions[0]).toMatchObject({ title: 'Pythagorean Theorem', titleLine: 2 });
  });

  it('strips a trailing {#id} from the heading title', () => {
    const regions = scanCallouts(doc('::: {.callout-note}\n## Callout with math {#x}\nbody\n:::'));
    expect(regions[0].title).toBe('Callout with math');
  });

  it('prefers an explicit attribute title over a heading', () => {
    const regions = scanCallouts(doc('::: {#thm-x name="Named"}\n## Heading\nbody\n:::'));
    expect(regions[0].title).toBe('Named');
    expect(regions[0].titleLine).toBeUndefined();
  });

  it('does not treat a non-leading heading as the title', () => {
    const regions = scanCallouts(doc('::: {#thm-x}\nprose first\n## Later\n:::'));
    expect(regions[0].title).toBeNull();
    expect(regions[0].titleLine).toBeUndefined();
  });

  it('tolerates leading whitespace and extra colons', () => {
    expect(parseFenceOpen('  :::: {#lem-euclid}')?.label).toBe('Lemma');
  });

  it('never classifies from an ID or class pattern inside a quoted title', () => {
    const remark = parseFenceOpen('::: {.remark name="see #thm-pythagoras"}');
    expect(remark?.type).toBe('remark');
    expect(remark?.numbered).toBe(false);
    expect(remark?.title).toBe('see #thm-pythagoras');

    const thm = parseFenceOpen('::: {#thm-x name="in the .proof style"}');
    expect(thm?.type).toBe('theorem');
    expect(thm?.numbered).toBe(true);

    // A title containing an ID pattern with no real ID/class outside quotes
    // is just a plain div — not a callout.
    expect(parseFenceOpen('::: {name="about #def-group"}')).toBeNull();
  });
});

describe('isFenceClose', () => {
  it('matches a bare fence', () => {
    expect(isFenceClose(':::')).toBe(true);
    expect(isFenceClose('  ::::  ')).toBe(true);
  });

  it('does not match an open fence', () => {
    expect(isFenceClose('::: {#thm-x}')).toBe(false);
  });

  it('does not match ordinary text', () => {
    expect(isFenceClose('a proof :::')).toBe(false);
  });
});

describe('scanCallouts', () => {
  it('finds a single closed region with its line span', () => {
    const regions = scanCallouts(doc('::: {#thm-x}\nbody\n:::'));
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
      '::: {#thm-a}',
      'a',
      ':::',
      '',
      '::: {#def-b}',
      'b',
      ':::',
      '',
      '::: {#thm-c}',
      'c',
      ':::',
    ].join('\n');
    const nums = scanCallouts(doc(src)).map((r) => `${r.type}${r.number}`);
    expect(nums).toEqual(['theorem1', 'definition1', 'theorem2']);
  });

  it('does not number proof / remark', () => {
    const regions = scanCallouts(doc('::: {.proof}\nqed\n:::'));
    expect(regions[0].number).toBeUndefined();
  });

  it('ignores an unterminated block (renders nothing until closed)', () => {
    expect(scanCallouts(doc('::: {#thm-x}\nstill typing'))).toHaveLength(0);
  });

  it('keeps blank lines inside the body within the region span', () => {
    const regions = scanCallouts(doc('::: {#thm-x}\nline 1\n\nline 2\n:::'));
    expect(regions[0]).toMatchObject({ openLine: 1, closeLine: 5 });
  });

  it('treats a nested open fence as body (non-nested v1)', () => {
    // The first `:::` after the outer open closes it; the inner open never fires.
    const regions = scanCallouts(doc('::: {#thm-x}\n::: {.proof}\nx\n:::'));
    expect(regions).toHaveLength(1);
    expect(regions[0]).toMatchObject({ type: 'theorem', openLine: 1, closeLine: 4 });
  });
});

describe('code fences are opaque to the scanner (H-8)', () => {
  it('a class-form callout inside a ``` fence stays raw', () => {
    expect(scanCallouts(doc('```\n::: {.callout-note}\nbody\n:::\n```'))).toHaveLength(0);
  });

  it('an ID-form callout inside a ``` fence stays raw', () => {
    expect(scanCallouts(doc('```\n::: {#thm-x}\nbody\n:::\n```'))).toHaveLength(0);
  });

  it('~~~ fences are opaque too', () => {
    expect(scanCallouts(doc('~~~\n::: {.callout-note}\nbody\n:::\n~~~'))).toHaveLength(0);
  });

  it('an open inside a fence does not pair with a close outside it', () => {
    expect(scanCallouts(doc('```\n::: {#thm-x}\n```\nbody\n:::'))).toHaveLength(0);
  });

  it('a close inside a fence does not close an open outside it', () => {
    // The ``` block sits inside the callout body; the `:::` INSIDE it must not
    // close the region — only the one after the fence does.
    const regions = scanCallouts(doc('::: {#thm-x}\nbody\n```\n:::\n```\n:::'));
    expect(regions).toHaveLength(1);
    expect(regions[0]).toMatchObject({ openLine: 1, closeLine: 6 });
  });

  it('a callout AFTER a closed fence still renders', () => {
    const regions = scanCallouts(doc('```\ncode\n```\n::: {#thm-x}\nbody\n:::'));
    expect(regions).toHaveLength(1);
    expect(regions[0]).toMatchObject({ type: 'theorem', openLine: 4, closeLine: 6, number: 1 });
  });
});

describe('closingFenceHideRange', () => {
  // The fence collapses via an INLINE replace that swallows the PRECEDING
  // line break too — otherwise the `:::` line stays as a phantom empty row.
  // (A block replace of the fence line was tried and reverted: block replaces
  // toggling on selection changes corrupt CM6 scroll/height geometry. The
  // math-as-last-body-line case is handled by hideTo absorption instead —
  // see calloutBlockAt and callout-fence-collapse.test.ts.)
  it('covers the newline before the fence, not just the fence text', () => {
    const src = '::: {#thm-x}\nbody\n:::';
    const d = doc(src);
    const r = scanCallouts(d)[0];
    const range = closingFenceHideRange(d, r);
    expect(range.from).toBe(d.line(2).to); // end of "body" — swallows the newline
    expect(range.to).toBe(d.line(3).to); // end of ":::"
    expect(range.from).toBeLessThan(d.line(3).from); // starts before the fence line
  });

  it('handles an empty-body callout (open then close)', () => {
    const src = '::: {#thm-x}\n:::';
    const d = doc(src);
    const r = scanCallouts(d)[0];
    const range = closingFenceHideRange(d, r);
    expect(range.from).toBe(d.line(1).to);
    expect(range.to).toBe(d.line(2).to);
  });
});

describe('figure divs', () => {
  it('recognises a #fig- div as a figure', () => {
    expect(parseFenceOpen('::: {#fig-growth}')).toMatchObject({
      type: 'figure',
      refId: 'fig-growth',
    });
  });

  it('leaves an unknown float prefix alone', () => {
    expect(parseFenceOpen('::: {#vid-clip}')).toBeNull();
  });
});
