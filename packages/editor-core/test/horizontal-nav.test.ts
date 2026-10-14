import { describe, it, expect } from 'vitest';
import { horizontalNavBindings, rowBoundaryPos } from '../src/editor/horizontal-nav';

/**
 * Option/Alt+Arrow is CodeMirror's own platform binding: group motion on mac,
 * syntax motion elsewhere. The keymap must not rebind it.
 */
describe('horizontal-nav: Alt+Arrow', () => {
  it('leaves Alt+Arrow to the default keymap', () => {
    expect(horizontalNavBindings.some((b) => /Alt-/.test(`${b.key} ${b.mac}`))).toBe(false);
  });
});

/**
 * On macOS/Catalyst, end/start of line is Cmd+Arrow — not Home/End — and must
 * route through the same self-correcting lineBoundary() clamp, or the coordinate hit-test overshoots
 * onto a different logical line near block-replace widgets (rendered tables,
 * display math). jsdom has no layout, so the clamp itself can't run here
 * (moveToLineBoundary throws and it defers); these tests pin the wiring,
 * which is the part that was missing when the bug shipped.
 */
describe('horizontal-nav: Cmd+Arrow line-boundary clamp wiring (mac)', () => {
  it.each(['Cmd-ArrowLeft', 'Cmd-ArrowRight'])('binds mac %s with run and shift handlers', (combo) => {
    const binding = horizontalNavBindings.find((b) => b.mac === combo);
    expect(binding).toBeDefined();
    expect(binding?.run).toBeTypeOf('function');
    expect(binding?.shift).toBeTypeOf('function');
    // mac-only on purpose: a cross-platform `key:` here would shadow Linux
    // Ctrl+Arrow word motion (Mod = Ctrl there).
    expect(binding?.key).toBeUndefined();
  });
});

/**
 * When the coordinate hit-test overshoots onto another logical line, the clamp
 * must land on the caret's VISUAL row boundary (Cmd+Left → start of the wrapped
 * row the caret sits on), not the logical line start. rowBoundaryPos computes
 * that by searching only within [from, to] using position→coords (the reliable
 * direction), so it can never cross onto another line.
 *
 * Synthetic layout, three wrapped rows on one logical line (positions 0..30):
 *   row1 = [0,10) top 0..16   row2 = [10,20) top 20..36   row3 = [20,30] top 40..56
 * A soft-wrap boundary position (10, 20) belongs to the previous row when probed
 * with assoc -1 and the next row with assoc +1 — which is why forward vs.
 * backward pass a differently-biased `rowAt`, mirroring view.coordsAtPos(pos, side).
 */
describe('horizontal-nav: rowBoundaryPos (visual-row clamp)', () => {
  const bands = [
    { from: 0, to: 10, top: 0, bottom: 16 },
    { from: 10, to: 20, top: 20, bottom: 36 },
    { from: 20, to: 31, top: 40, bottom: 56 },
  ];
  const bandOf = (pos: number, side: number) => {
    // Bias a wrap-boundary position to the previous row for -1, next row for +1.
    const p = side < 0 ? pos - 0.5 : pos;
    for (const b of bands) if (p >= b.from && p < b.to) return { top: b.top, bottom: b.bottom };
    return null;
  };
  const rowAtBwd = (pos: number) => bandOf(pos, 1); // Cmd+Left probes with +1
  const rowAtFwd = (pos: number) => bandOf(pos, -1); // Cmd+Right probes with -1

  it('backward lands on the start of the caret’s visual row', () => {
    expect(rowBoundaryPos(0, 30, 25, false, rowAtBwd)).toBe(20); // last row → its start
    expect(rowBoundaryPos(0, 30, 5, false, rowAtBwd)).toBe(0); // first row → logical start
    expect(rowBoundaryPos(0, 30, 10, false, rowAtBwd)).toBe(10); // wrap-boundary caret → row2 start
  });

  it('forward lands on the end of the caret’s visual row', () => {
    expect(rowBoundaryPos(0, 30, 25, true, rowAtFwd)).toBe(30); // last row → logical end
    expect(rowBoundaryPos(0, 30, 5, true, rowAtFwd)).toBe(10); // first row → wrap point
    expect(rowBoundaryPos(0, 30, 15, true, rowAtFwd)).toBe(20); // middle row → its wrap point
  });

  it('falls back to the logical boundary when coords are unavailable', () => {
    const noCoords = () => null;
    expect(rowBoundaryPos(0, 30, 25, false, noCoords)).toBe(0);
    expect(rowBoundaryPos(0, 30, 25, true, noCoords)).toBe(30);
  });
});
