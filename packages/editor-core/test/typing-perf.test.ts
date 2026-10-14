import { describe, it, expect, beforeAll } from 'vitest';
import { EditorView } from '@codemirror/view';
import { createEditorState } from '../src/editor/setup';
import { __scanCount, __resetScanCount } from '../src/editor/tex-math';
import { __docTextCount, __resetDocTextCount } from '../src/utils/doc-text';

/**
 * Typing-latency regression guard for the TeX editor hot path.
 *
 * Before the shared `mathRegionsField`, every keystroke AND every caret move
 * in a `.tex` document re-ran `scanMathRegions(doc.toString())` from scratch —
 * the math-render StateField on `docChanged || selection`, plus the hsnips /
 * tabout / item-newline / math-wrap math-context gate. On a large document
 * that O(n) scan (+ full-string allocation) ran 1–4× per event.
 *
 * The field caches the regions and recomputes them only on `docChanged`, so:
 *   - caret motion does ZERO scans (reads the cache), and
 *   - typing does exactly ONE scan per document change.
 *
 * These asserts lock that invariant in. They also print the wall-clock cost so
 * the numbers can be compared before/after.
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

/** ~1000-line .tex doc with ~80 inline + ~57 display math regions. */
function largeTexDoc(): string {
  const lines: string[] = [];
  for (let i = 0; i < 400; i++) {
    lines.push(`This is plain prose line ${i} with several words to fill out the line.`);
    if (i % 5 === 0) lines.push(`Inline math $a_{${i}} + b^{${i}} = c_{${i}}$ sits inside the text.`);
    if (i % 7 === 0) lines.push('$$', `\\int_0^{${i}} f(x)\\,\\mathrm{d}x = ${i}`, '$$');
  }
  return lines.join('\n');
}

function makeTexView(doc: string): EditorView {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  const state = createEditorState(doc, { onContentChange: () => {} }, 'tex');
  return new EditorView({ state, parent });
}

describe('TeX typing hot path', () => {
  const N = 100;

  it(`caret motion does no math rescans across ${N} moves`, () => {
    const view = makeTexView(largeTexDoc());
    const docLen = view.state.doc.length;

    __resetScanCount();
    const t0 = performance.now();
    for (let k = 0; k < N; k++) {
      // Walk the caret through the document, selection-only transactions.
      const pos = Math.floor((docLen * k) / N);
      view.dispatch({ selection: { anchor: pos } });
    }
    const ms = performance.now() - t0;
    const scans = __scanCount();
    // eslint-disable-next-line no-console
    console.log(`[perf] caret motion: ${scans} scans over ${N} moves, ${ms.toFixed(1)}ms total (${(ms / N).toFixed(3)}ms/move)`);

    expect(scans).toBe(0);
    view.destroy();
  });

  it(`typing does exactly one math rescan per keystroke (${N} chars)`, () => {
    const view = makeTexView(largeTexDoc());
    // Insert at offset 0 — plain prose, not inside any math region.
    view.dispatch({ selection: { anchor: 0 } });

    __resetScanCount();
    const t0 = performance.now();
    for (let k = 0; k < N; k++) {
      const pos = view.state.selection.main.head;
      view.dispatch({ changes: { from: pos, insert: 'x' }, selection: { anchor: pos + 1 } });
    }
    const ms = performance.now() - t0;
    const scans = __scanCount();
    // eslint-disable-next-line no-console
    console.log(`[perf] typing: ${scans} scans over ${N} keystrokes, ${ms.toFixed(1)}ms total (${(ms / N).toFixed(3)}ms/key)`);

    expect(scans).toBe(N);
    view.destroy();
  });

  it(`flattens the document once per keystroke, not once per consumer (${N} chars)`, () => {
    // A `.tex` keystroke used to materialise the whole document THREE times:
    // scanMathRegions, styleRegionsFor (tex-decorations) and setup.ts's
    // content notifier each called `doc.toString()` on the same new `Text`.
    // At 250KB that is three full copies per character, and V8's string
    // flatten was 4.5% of keystroke script time in the bundle profile
    // (2026-08-26). They share one flatten now, cached per `Text` — the same
    // WeakMap-on-immutable-doc trick every scanner here already uses.
    const view = makeTexView(largeTexDoc());
    view.dispatch({ selection: { anchor: 0 } });

    __resetDocTextCount();
    for (let k = 0; k < N; k++) {
      const pos = view.state.selection.main.head;
      view.dispatch({ changes: { from: pos, insert: 'x' }, selection: { anchor: pos + 1 } });
    }
    const flattens = __docTextCount();
    // eslint-disable-next-line no-console
    console.log(`[perf] typing: ${flattens} document flattens over ${N} keystrokes`);

    expect(flattens).toBe(N);
    view.destroy();
  });
});
