import { describe, it, expect, beforeAll } from 'vitest';
import { EditorView } from '@codemirror/view';
import { EditorState, EditorSelection } from '@codemirror/state';
import { tryMathWrap } from '../src/editor/math-wrap';

beforeAll(() => {
  if (typeof Range.prototype.getClientRects !== 'function') {
    Range.prototype.getClientRects = () => [] as unknown as DOMRectList;
  }
  if (typeof Range.prototype.getBoundingClientRect !== 'function') {
    Range.prototype.getBoundingClientRect = () =>
      ({ x: 0, y: 0, width: 0, height: 0, top: 0, right: 0, bottom: 0, left: 0, toJSON: () => ({}) }) as DOMRect;
  }
});

function makeView(doc: string, from: number, to: number): EditorView {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  const state = EditorState.create({
    doc,
    selection: EditorSelection.range(from, to),
  });
  return new EditorView({ state, parent });
}

describe('tryMathWrap — math context, non-empty selection', () => {
  it('wraps with \\left( … \\right) on "("', () => {
    // doc:   $x^2$  selection over `x^2` is [1,4]
    const view = makeView('$x^2$', 1, 4);
    const ok = tryMathWrap(view, 1, 4, '(', () => true);
    expect(ok).toBe(true);
    expect(view.state.doc.toString()).toBe('$\\left(x^2\\right)$');
    // Inner selection covers the original text:
    expect(view.state.selection.main.from).toBe(1 + '\\left('.length);
    expect(view.state.selection.main.to).toBe(1 + '\\left('.length + 3);
    view.destroy();
  });

  it('wraps with \\left[ … \\right] on "["', () => {
    const view = makeView('$abc$', 1, 4);
    const ok = tryMathWrap(view, 1, 4, '[', () => true);
    expect(ok).toBe(true);
    expect(view.state.doc.toString()).toBe('$\\left[abc\\right]$');
    view.destroy();
  });
});

describe('tryMathWrap — fall-through cases', () => {
  it('returns false on empty selection (lets ;( hsnip fire)', () => {
    const view = makeView('$x$', 1, 1);
    const ok = tryMathWrap(view, 1, 1, '(', () => true);
    expect(ok).toBe(false);
    expect(view.state.doc.toString()).toBe('$x$');
    view.destroy();
  });

  it('returns false on unsupported delim like "{" (no wrap mapping)', () => {
    const view = makeView('$abc$', 1, 4);
    const ok = tryMathWrap(view, 1, 4, '{', () => true);
    expect(ok).toBe(false);
    view.destroy();
  });

  it('returns false outside math context (autopair takes over)', () => {
    const view = makeView('abc', 0, 3);
    const ok = tryMathWrap(view, 0, 3, '(', () => false);
    expect(ok).toBe(false);
    view.destroy();
  });
});

describe('tryMathWrap — boundary straddling', () => {
  it('rejects when "from" is in math but "to" is outside', () => {
    // doc:  $abc$rest  — selection [1,7] runs from inside math past `$`
    const view = makeView('$abc$rest', 1, 7);
    // Math context true for positions inside the dollars; false past it.
    // Math region.to is the position one past the closing `$`, i.e. 5.
    const inMath = (_state: EditorState, pos: number) => pos >= 1 && pos < 5;
    const ok = tryMathWrap(view, 1, 7, '(', inMath);
    expect(ok).toBe(false);
    expect(view.state.doc.toString()).toBe('$abc$rest');
    view.destroy();
  });

  it('accepts when "to" sits exactly at the closing $ (to - 1 still in math)', () => {
    // Selection ending at index 4 (the position of closing `$`) should
    // still be considered fully in-math: to - 1 = 3 is the `c`.
    const view = makeView('$abc$', 1, 4);
    const inMath = (_state: EditorState, pos: number) => pos >= 1 && pos < 5;
    const ok = tryMathWrap(view, 1, 4, '(', inMath);
    expect(ok).toBe(true);
    expect(view.state.doc.toString()).toBe('$\\left(abc\\right)$');
    view.destroy();
  });
});
