import { describe, it, expect } from 'vitest';
import { EditorView } from '@codemirror/view';
import { createEditorState } from '../src/editor/setup';
import { __calloutScanCount, __resetCalloutScanCount } from '../src/editor/callout-core';

/**
 * Perf regression guard for the callout hot path, mirroring typing-perf.test.ts.
 *
 * Callout regions used to be rescanned over the whole document on EVERY
 * selection change (the decorations StateField), and again once per
 * DisplayMath node per transaction (`calloutBlockAt` in the math fields) —
 * O(blocks × lines) per keystroke. The scanners are now cached by `Text`
 * identity (see makeCachedScanner), so:
 *   - caret motion does ZERO scans (same immutable `Text`, cache hit), and
 *   - typing does at most ONE scan per document change, shared by all
 *     consumers.
 */

/** ~500-line .md doc with 30 theorem callouts each containing display math. */
function largeMdDoc(): string {
  const lines: string[] = [];
  for (let i = 0; i < 300; i++) {
    lines.push(`Prose line ${i} with some **bold** text to fill out the line.`);
    if (i % 10 === 0) {
      lines.push(`::: {#thm-t${i}}`, `Statement ${i}.`, '$$', `x_{${i}}^2 + 1`, '$$', ':::');
    }
  }
  return lines.join('\n');
}

function makeMdView(doc: string): EditorView {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  const state = createEditorState(doc, { onContentChange: () => {} }, 'md');
  return new EditorView({ state, parent });
}

describe('callout scan cache', () => {
  const N = 50;

  it(`caret motion does no callout rescans across ${N} moves`, () => {
    const view = makeMdView(largeMdDoc());
    const docLen = view.state.doc.length;

    __resetCalloutScanCount();
    for (let k = 0; k < N; k++) {
      view.dispatch({ selection: { anchor: Math.floor((docLen * k) / N) } });
    }
    expect(__calloutScanCount()).toBe(0);
    view.destroy();
  });

  it(`typing does at most one callout rescan per keystroke (${N} chars)`, () => {
    const view = makeMdView(largeMdDoc());
    view.dispatch({ selection: { anchor: 0 } });

    __resetCalloutScanCount();
    for (let k = 0; k < N; k++) {
      const pos = view.state.selection.main.head;
      view.dispatch({ changes: { from: pos, insert: 'x' }, selection: { anchor: pos + 1 } });
    }
    const scans = __calloutScanCount();
    expect(scans).toBeGreaterThan(0);
    expect(scans).toBeLessThanOrEqual(N);
    view.destroy();
  });
});
