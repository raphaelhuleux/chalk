import { describe, it, expect, afterEach } from 'vitest';
import { mdView, destroyViews } from './helpers/views';
import {
  outlineNodeAt,
  prevSibling,
  nextSibling,
  foldableNodes,
  parseListLine,
} from '../src/editor/md-outline-tree';

afterEach(() => destroyViews());

const node = (doc: string, line: number) => outlineNodeAt(mdView(doc).state, line);

describe('list item subtree', () => {
  it('covers children and continuation lines', () => {
    const n = node('- a\n  more\n    - b\n        - c\n- d', 1);
    expect(n).toMatchObject({ kind: 'item', line: 1, end: 4, level: 0 });
  });

  it('keeps a loose child but not trailing blank lines', () => {
    expect(node('- a\n\n    - b\n\n- c', 1)?.end).toBe(3);
    expect(node('- a\n    - b\n\n\nText', 1)?.end).toBe(2);
  });

  it('a leaf item is its own subtree', () => {
    expect(node('- a\n- b', 1)?.end).toBe(1);
  });

  it('ignores list-looking lines in fenced code', () => {
    expect(node('```\n- a\n```', 2)).toBeNull();
  });

  it('parses task boxes and ordered markers', () => {
    expect(parseListLine('  12) [x] done')).toMatchObject({
      kind: 'ordered',
      indent: '  ',
      marker: '12)',
      box: '[x] ',
      bodyOffset: 10,
      num: 12,
    });
  });
});

describe('heading section', () => {
  const doc = '# A\ntext\n\n## B\nb\n\n## C\nc\n\n# D\nd';

  it('runs to the next heading of the same or higher level, no trailing blanks', () => {
    expect(node(doc, 1)).toMatchObject({ kind: 'heading', level: 1, end: 8 });
    expect(node(doc, 4)).toMatchObject({ kind: 'heading', level: 2, end: 5 });
    expect(node(doc, 10)?.end).toBe(11);
  });

  it('handles Setext headings', () => {
    const n = node('Title\n=====\nbody\n\nNext\n====', 1);
    expect(n).toMatchObject({ kind: 'heading', level: 1, headEnd: 2, end: 3 });
  });

  it('extends over a display-math block or callout it would cut', () => {
    const math = node('# A\n$$\nx\n$$\n# B', 1);
    expect(math?.end).toBe(4);
    const callout = node('# A\n::: {.proof}\n## B\nbody\n:::\n# C', 1);
    expect(callout?.end).toBe(5);
  });

  it('a heading inside a callout ends at the callout body', () => {
    const n = node('::: {.proof}\nintro\n\n## B\nbody\n:::\nafter', 4);
    expect(n?.end).toBe(5);
  });

  it('a callout title heading has no section', () => {
    expect(node('::: {#thm-a}\n## Title\nbody\n:::', 2)).toBeNull();
  });
});

describe('siblings', () => {
  it('finds item siblings at the same depth only', () => {
    const view = mdView('- a\n    - a1\n- b\n    - b1\n    - b2\n- c');
    const s = view.state;
    const b = outlineNodeAt(s, 3)!;
    expect(prevSibling(s, b)?.line).toBe(1);
    expect(nextSibling(s, b)?.line).toBe(6);
    const b1 = outlineNodeAt(s, 4)!;
    expect(prevSibling(s, b1)).toBeNull();
    expect(nextSibling(s, b1)?.line).toBe(5);
    expect(nextSibling(s, outlineNodeAt(s, 5)!)).toBeNull();
  });

  it('finds heading siblings within the parent section', () => {
    const view = mdView('# A\n## A1\n## A2\n# B\n## B1');
    const s = view.state;
    expect(prevSibling(s, outlineNodeAt(s, 3)!)?.line).toBe(2);
    expect(nextSibling(s, outlineNodeAt(s, 3)!)).toBeNull();
    expect(prevSibling(s, outlineNodeAt(s, 5)!)).toBeNull();
    expect(nextSibling(s, outlineNodeAt(s, 1)!)?.line).toBe(4);
  });
});

describe('foldableNodes', () => {
  it('lists only nodes with something to hide', () => {
    const view = mdView('# A\n- a\n    - b\n- c\n# B');
    expect(foldableNodes(view.state).map((n) => n.line)).toEqual([1, 2]);
  });
});
