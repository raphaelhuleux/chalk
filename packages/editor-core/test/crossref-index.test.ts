import { describe, it, expect, beforeEach } from 'vitest';
import { Text } from '@codemirror/state';
import {
  crossrefIndex,
  __crossrefScanCount,
  __resetCrossrefScanCount,
} from '../src/editor/crossref-index';

const doc = (s: string): Text => Text.of(s.split('\n'));

describe('crossrefIndex — sections', () => {
  it('numbers labelled sections hierarchically', () => {
    const src = [
      '# Setup {#sec-setup}',
      '',
      '## Numbered equations {#sec-equations}',
      '',
      '# Theorem-like blocks {#sec-theorems}',
    ].join('\n');
    const idx = crossrefIndex(doc(src));
    expect(idx.get('sec-setup')).toMatchObject({ kind: 'sec', label: 'Section', number: '1' });
    expect(idx.get('sec-equations')?.number).toBe('1.1');
    expect(idx.get('sec-theorems')?.number).toBe('2');
  });

  it('counts unlabelled headings toward the numbering but does not index them', () => {
    const src = ['# A {#sec-a}', '# Unlabelled', '# C {#sec-c}'].join('\n');
    const idx = crossrefIndex(doc(src));
    expect(idx.get('sec-a')?.number).toBe('1');
    expect(idx.get('sec-c')?.number).toBe('3');
    expect(idx.has('sec-b')).toBe(false);
  });

  it('does not count a callout title heading as a section', () => {
    const src = [
      '# Real section {#sec-one}',
      '',
      '::: {#thm-x}',
      '## Inner Theorem Title',
      'body',
      ':::',
      '',
      '# Next section {#sec-two}',
    ].join('\n');
    const idx = crossrefIndex(doc(src));
    expect(idx.get('sec-one')?.number).toBe('1');
    expect(idx.get('sec-two')?.number).toBe('2'); // inner ## did not bump to 3
  });

  it('zero-fills the levels a heading skips over', () => {
    const src = ['# A {#sec-a}', '', '### B {#sec-b}'].join('\n');
    const idx = crossrefIndex(doc(src));
    expect(idx.get('sec-b')?.number).toBe('1.0.1');
  });

  it('zero-fills the missing top level when the document starts at ##', () => {
    const src = ['## A {#sec-a}', '', '## B {#sec-b}'].join('\n');
    const idx = crossrefIndex(doc(src));
    expect(idx.get('sec-a')?.number).toBe('0.1');
    expect(idx.get('sec-b')?.number).toBe('0.2');
  });

  it('ignores a heading inside a fenced code block', () => {
    const src = [
      '# A {#sec-a}',
      '',
      '```bash',
      '# not a heading, just a shell comment',
      '```',
      '',
      '# B {#sec-b}',
    ].join('\n');
    const idx = crossrefIndex(doc(src));
    expect(idx.get('sec-b')?.number).toBe('2');
  });

  it('does not index a labelled heading written inside a fenced code block', () => {
    const src = ['```markdown', '# Sample {#sec-sample}', '```'].join('\n');
    expect(crossrefIndex(doc(src)).has('sec-sample')).toBe(false);
  });
});

describe('crossrefIndex — equations', () => {
  it('numbers labelled display equations globally, in document order', () => {
    const src = [
      '$$',
      'y = x',
      '$$ {#eq-ols}',
      '',
      '$$',
      'a = b',
      '$$ {#eq-budget}',
      '',
      '$$',
      'unlabelled = 0',
      '$$',
      '',
      '::: {#thm-x}',
      '$$',
      'c^2',
      '$$ {#eq-pythagoras}',
      ':::',
    ].join('\n');
    const idx = crossrefIndex(doc(src));
    expect(idx.get('eq-ols')?.number).toBe('1');
    expect(idx.get('eq-budget')?.number).toBe('2');
    expect(idx.get('eq-pythagoras')?.number).toBe('3'); // nested but still global #3
    expect(idx.get('eq-ols')?.kind).toBe('eq');
  });

  it('indexes the single-line and multi-line labelled forms', () => {
    const src = [
      '$$ E = mc^2 $$ {#eq-mc2}',
      '',
      '$$ a +',
      'b $$ {#eq-ab}',
      '',
      '$$',
      'y = x',
      '$$ {#eq-ols}',
    ].join('\n');
    const idx = crossrefIndex(doc(src));
    expect(idx.get('eq-mc2')?.number).toBe('1');
    expect(idx.get('eq-ab')?.number).toBe('2');
    expect(idx.get('eq-ols')?.number).toBe('3');
  });

  it('ignores an equation label inside a fenced code block', () => {
    const src = [
      '```markdown',
      '$$',
      'e = mc^2',
      '$$ {#eq-in-code}',
      '```',
      '',
      '$$',
      'y = x',
      '$$ {#eq-real}',
    ].join('\n');
    const idx = crossrefIndex(doc(src));
    expect(idx.has('eq-in-code')).toBe(false);
    expect(idx.get('eq-real')?.number).toBe('1'); // the sample did not consume #1
  });
});

describe('crossrefIndex — callouts', () => {
  it('maps a theorem refId to its per-type number', () => {
    const src = ['::: {#thm-a}\nx\n:::', '', '::: {#def-b}\ny\n:::', '', '::: {#thm-c}\nz\n:::'].join(
      '\n',
    );
    const idx = crossrefIndex(doc(src));
    expect(idx.get('thm-a')).toMatchObject({ kind: 'theorem', label: 'Theorem', number: '1' });
    expect(idx.get('def-b')?.number).toBe('1');
    expect(idx.get('thm-c')?.number).toBe('2');
  });

  it('registers unnumbered proof-like refs with a null number', () => {
    const idx = crossrefIndex(doc('::: {#prf-x}\nqed\n:::'));
    expect(idx.get('prf-x')).toMatchObject({ kind: 'proof', label: 'Proof', number: null });
  });
});

describe('crossrefIndex — frontmatter', () => {
  it('does not read a YAML comment as a heading', () => {
    const src = ['---', '# a YAML comment', 'title: Notes', '---', '', '# Intro {#sec-intro}'].join('\n');
    expect(crossrefIndex(doc(src)).get('sec-intro')?.number).toBe('1');
  });
});

describe('crossrefIndex — caching', () => {
  beforeEach(() => __resetCrossrefScanCount());

  it('scans once per Text identity', () => {
    const d = doc('# A {#sec-a}');
    crossrefIndex(d);
    crossrefIndex(d);
    expect(__crossrefScanCount()).toBe(1);
  });
});

describe('crossrefIndex — figures', () => {
  const FIG = [
    '::: {#fig-growth}',
    '![](figures/growth.png)',
    '',
    'Notes: Shaded bands are 95% CIs.',
    '',
    'Real GDP growth',
    ':::',
  ].join('\n');

  it('numbers a figure div and resolves its label', () => {
    const idx = crossrefIndex(doc(FIG));
    expect(idx.get('fig-growth')).toEqual({
      kind: 'figure',
      label: 'Figure',
      number: '1',
    });
  });

  it('counts figures on their own counter, not the theorem one', () => {
    const src = [
      '::: {#thm-one}',
      'body',
      ':::',
      '',
      FIG,
    ].join('\n');
    const idx = crossrefIndex(doc(src));
    expect(idx.get('thm-one')?.number).toBe('1');
    expect(idx.get('fig-growth')?.number).toBe('1');
  });
});
