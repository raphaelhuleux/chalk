import { describe, it, expect } from 'vitest';
import { EditorSelection, Text } from '@codemirror/state';
import { calloutBlockAt } from '../src/editor/callout-core';
import { scanCallouts } from '../src/editor/md-callout-plugin';
import { scanTexCallouts } from '../src/editor/tex-callout-plugin';
import { createEditor } from '../src/editor/setup';
import { parsed } from './helpers/force-parse';

const doc = (s: string): Text => Text.of(s.split('\n'));

/** Offsets of the `$$…$$` block on the given 1-based line (single-line form). */
function blockRange(d: Text, lineNo: number): [number, number] {
  const line = d.line(lineNo);
  return [line.from, line.to];
}

describe('calloutBlockAt', () => {
  // 1 open, 2 text, 3 display-math, 4 close.
  const SRC = [
    '::: {#thm-pythagoras name="Pythagoras"}',
    'For a right triangle,',
    '$$a^2+b^2=c^2$$',
    ':::',
  ].join('\n');
  const d = doc(SRC);

  it('reports the callout type for a block strictly inside the region', () => {
    const [from, to] = blockRange(d, 3);
    expect(calloutBlockAt(d, scanCallouts, from, to)).toMatchObject({ type: 'theorem' });
  });

  it('marks the block as the visual bottom when it is the last body line', () => {
    const [from, to] = blockRange(d, 3); // line 3 is the last row before the hidden `:::`
    expect(calloutBlockAt(d, scanCallouts, from, to)?.bottom).toBe(true);
  });

  it('drops bottom when the caret reveals the closing fence below', () => {
    const [from, to] = blockRange(d, 3);
    // Caret parked on the `:::` line: that line is revealed and carries the
    // box bottom itself, so the widget must not also draw bottom corners.
    const onClose = EditorSelection.cursor(d.line(4).from);
    expect(calloutBlockAt(d, scanCallouts, from, to, onClose)?.bottom).toBe(false);
    // Caret elsewhere keeps the widget as the bottom row.
    const elsewhere = EditorSelection.cursor(d.line(2).from);
    expect(calloutBlockAt(d, scanCallouts, from, to, elsewhere)?.bottom).toBe(true);
  });

  it('does not mark the block as bottom when text follows it', () => {
    const src = [
      '::: {#thm-pythagoras name="Pythagoras"}',
      '$$a^2+b^2=c^2$$',
      'Therefore it holds.',
      ':::',
    ].join('\n');
    const d2 = doc(src);
    const [from, to] = blockRange(d2, 2);
    const r = calloutBlockAt(d2, scanCallouts, from, to);
    expect(r?.type).toBe('theorem');
    expect(r?.bottom).toBe(false);
  });

  it('returns null for a block outside any callout', () => {
    const src = 'text\n$$a^2$$\nmore';
    const d3 = doc(src);
    const [from, to] = blockRange(d3, 2);
    expect(calloutBlockAt(d3, scanCallouts, from, to)).toBeNull();
  });

  it('returns null for the open fence line itself', () => {
    const [from, to] = blockRange(d, 1);
    expect(calloutBlockAt(d, scanCallouts, from, to)).toBeNull();
  });
});

describe('calloutBlockAt — tex environments', () => {
  // Same shape as the md cases, driven by the LaTeX scanner: the two hosts
  // must classify blocks identically for the boxes to stay pixel-identical.
  const SRC = [
    '\\begin{theorem}[Pythagoras]',
    'For a right triangle,',
    '$$a^2+b^2=c^2$$',
    '\\end{theorem}',
  ].join('\n');
  const d = doc(SRC);

  it('reports type, bottom, and the fence-absorbing hideTo for a box-bottom block', () => {
    const [from, to] = blockRange(d, 3);
    expect(calloutBlockAt(d, scanTexCallouts, from, to)).toEqual({
      type: 'theorem',
      bottom: true,
      hideTo: d.line(4).to, // the math replace extends through \end{theorem}
    });
  });

  it('does not mark bottom (nor hideTo) when text follows the block', () => {
    const d2 = doc(['\\begin{proof}', '$$a^2$$', 'QED.', '\\end{proof}'].join('\n'));
    const [from, to] = blockRange(d2, 2);
    expect(calloutBlockAt(d2, scanTexCallouts, from, to)).toEqual({ type: 'proof', bottom: false });
  });

  it('returns null outside any environment', () => {
    const d3 = doc('text\n$$a^2$$\nmore');
    const [from, to] = blockRange(d3, 2);
    expect(calloutBlockAt(d3, scanTexCallouts, from, to)).toBeNull();
  });
});

describe('tex display math inside a callout (widget classes)', () => {
  it('tags the rendered math widget so the box continues through it', () => {
    document.body.innerHTML = '';
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const view = parsed(createEditor(
      parent,
      ['intro', '\\begin{theorem}', 'Statement,', '$$a^2+b^2=c^2$$', 'more text', '\\end{theorem}'].join('\n'),
      { onContentChange: () => {} },
      'tex',
    ));
    // Caret sits at 0 ("intro"), outside the block → rendered widget mode.
    const widget = view.dom.querySelector('.cm-tex-math-display');
    expect(widget).not.toBeNull();
    expect(widget!.classList.contains('cm-callout')).toBe(true);
    expect(widget!.classList.contains('cm-callout-theorem')).toBe(true);
    expect(widget!.classList.contains('cm-callout-bottom')).toBe(false);
    view.destroy();
    parent.remove();
  });
});
