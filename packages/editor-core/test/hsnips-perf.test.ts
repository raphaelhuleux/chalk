import { describe, it, expect, beforeAll } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { EditorView } from '@codemirror/view';
import { createEditorState } from '../src/editor/setup';
import { parseHSnips } from '../src/editor/hsnips-parser';
import {
  setSnippets,
  __contextEvalCount,
  __resetContextEvalCount,
} from '../src/editor/hsnips-plugin';

/**
 * Keystroke-cost regression guard for the snippet engine, with the REAL
 * bundled snippet set loaded (assets/latex.hsnips, ~230 automatic snippets
 * carrying a math(context) filter).
 *
 * The context predicate depends only on (state, pos) — fixed for one
 * `findMatch` call — so it must be evaluated at most ONCE per keystroke.
 * Before the per-call memo it ran once per candidate snippet: ~230 full
 * math-region walks per character in prose, plus ~230 O(col²)
 * `isInLatexTextSpan` scans per character inside math.
 *
 * Each scenario also asserts the doc grew by exactly one char per keystroke,
 * proving no snippet auto-expanded (expansions would dispatch extra
 * transactions and muddy the count).
 */

beforeAll(() => {
  if (typeof Range.prototype.getClientRects !== 'function') {
    Range.prototype.getClientRects = () => [] as unknown as DOMRectList;
  }
  if (typeof Range.prototype.getBoundingClientRect !== 'function') {
    Range.prototype.getBoundingClientRect = () =>
      ({ x: 0, y: 0, width: 0, height: 0, top: 0, right: 0, bottom: 0, left: 0, toJSON: () => ({}) }) as DOMRect;
  }
});

const here = dirname(fileURLToPath(import.meta.url));
const bundledSnippets = parseHSnips(
  readFileSync(resolve(here, '../assets/latex.hsnips'), 'utf8'),
);

const DOC = [
  'Plain prose line with several words and no markup at all here.',
  'Inline math $a_i + b^j = c_k$ sits inside the text.',
  '$$',
  '\\int_0^1 f(x)\\,\\mathrm{d}x = 1',
  '$$',
  'More trailing prose to park the caret in.',
].join('\n');

function makeTexView(): EditorView {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  const state = createEditorState(DOC, { onContentChange: () => {} }, 'tex');
  const view = new EditorView({ state, parent });
  view.dispatch({ effects: [setSnippets.of(bundledSnippets)] });
  return view;
}

function typeChars(view: EditorView, at: number, ch: string, n: number): void {
  view.dispatch({ selection: { anchor: at } });
  for (let k = 0; k < n; k++) {
    const pos = view.state.selection.main.head;
    view.dispatch({ changes: { from: pos, insert: ch }, selection: { anchor: pos + 1 } });
  }
}

describe('hsnips context filter cost', () => {
  const N = 20;

  it(`prose typing evaluates the math context at most once per keystroke (${N} chars)`, () => {
    const view = makeTexView();
    const len0 = view.state.doc.length;
    __resetContextEvalCount();
    typeChars(view, 0, 'q', N);
    expect(view.state.doc.length).toBe(len0 + N); // no expansion fired
    expect(__contextEvalCount()).toBeLessThanOrEqual(N);
    view.destroy();
  });

  it(`math typing evaluates the math context at most once per keystroke (${N} chars)`, () => {
    const view = makeTexView();
    // Caret right after the '+' operator: every digit-combining auto regex in
    // the bundled set (`a1` → subscript, `x,,` → slant bold, …) requires a
    // LETTER immediately before the typed char, so '0' after '+' is inert.
    // (Verified live: '1' after 'a' fired auto-subscript; ',' after 'a'
    // fired slant-bold.)
    const inMath = view.state.doc.toString().indexOf('+ b') + 1;
    const len0 = view.state.doc.length;
    __resetContextEvalCount();
    typeChars(view, inMath, '0', N);
    expect(view.state.doc.length).toBe(len0 + N); // no expansion fired
    expect(__contextEvalCount()).toBeLessThanOrEqual(N);
    view.destroy();
  });
});
