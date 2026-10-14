import { describe, it, expect, afterEach } from 'vitest';
import { EditorSelection } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { destroyViews, langView } from './helpers/views';
import { probeHidden, probeAtomic } from '../src/debug-probe';
import { structuralCells, type MatrixCell } from '../../../Tests/matrix/compose.mjs';
import {
  predictHidden,
  predictAtomic,
  predictHorizontal,
  constructExtents,
  ruleForRange,
  type Sel,
} from '../../../Tests/matrix/rules.mjs';

/**
 * Structural lane of the discovery matrix (see Tests/matrix/README.md).
 *
 * Mounts every composed cell (compose.mjs) in jsdom, walks every caret
 * position plus a set of Shift-selections, and asserts the oracle
 * invariants of docs/specs/2026-08-23-caret-and-reveal-semantics.md:
 *
 *   O-1  nothing outside a catalogued construct extent is ever hidden;
 *   O-2  the merged hidden set equals the rules.mjs prediction exactly;
 *   O-5  concealment is a pure function of (doc, selection): revisiting a
 *        position after the walk reproduces the identical hidden set;
 *   R-H1/R-H2  synthetic Left/Right keydowns move one position (ASCII docs;
 *        the grapheme dimension is owned by the caret fixtures) and cross
 *        the GFM table atomically.
 *
 * Expectations come from rules.mjs ONLY — never from recorded output.
 * Violations are collected per cell and asserted empty, so one red cell
 * reports every offending position with its rule ID at once.
 */

const mount = (cell: MatrixCell): EditorView =>
  langView(cell.doc, cell.language, { ensureTree: true, cursor: 0 });

afterEach(destroyViews);

function setSel(view: EditorView, sel: Sel): void {
  view.dispatch({ selection: EditorSelection.range(sel.anchor, sel.head) });
}

function extentsOf(view: EditorView): Array<{ from: number; to: number; block: boolean }> {
  return probeHidden(view).map(({ from, to, block }) => ({ from, to, block }));
}

function fmt(list: Array<{ from: number; to: number; block: boolean }>): string {
  return list.map((h) => `[${h.from},${h.to})${h.block ? 'B' : ''}`).join(' ') || '(none)';
}

function press(view: EditorView, key: string, shiftKey = false): void {
  view.contentDOM.dispatchEvent(
    new KeyboardEvent('keydown', { key, shiftKey, bubbles: true, cancelable: true }),
  );
}

/** Interesting boundary heads for the Shift-selection and horizontal passes:
 *  every instance edge plus one position either side of it. */
function boundaryHeads(cell: MatrixCell): number[] {
  const out = new Set<number>();
  for (const [f, t] of constructExtents(cell)) {
    for (const p of [f - 1, f, f + 1, t - 1, t, t + 1]) {
      if (p >= 0 && p <= cell.doc.length) out.add(p);
    }
  }
  return [...out].sort((a, b) => a - b);
}

const cells = structuralCells();

describe('matrix structural lane', () => {
  for (const cell of cells) {
    it(cell.id, () => {
      const view = mount(cell);
      const violations: string[] = [];
      const firstPass = new Map<number, string>();

      // ---- caret walk: every position, O-1 + O-2 -------------------------
      for (let head = 0; head <= cell.doc.length; head++) {
        setSel(view, { anchor: head, head });
        const got = extentsOf(view);
        firstPass.set(head, JSON.stringify(got));

        const whitelist = constructExtents(cell);
        for (const h of got) {
          if (!whitelist.some(([f, t]) => h.from >= f && h.to <= t)) {
            // A merged range may legally span several abutting extents; only
            // flag it when no COVER by the union exists either.
            let pos = h.from;
            const covered = () => {
              for (let guard = 0; guard < 64 && pos < h.to; guard++) {
                const ext = whitelist.find(([f, t]) => pos >= f && pos < t);
                if (!ext) return false;
                pos = ext[1];
              }
              return pos >= h.to;
            };
            if (!covered()) {
              violations.push(`O-1 head=${head}: hidden [${h.from},${h.to}) outside every extent`);
            }
          }
        }

        const want = predictHidden(cell, { anchor: head, head });
        if (JSON.stringify(got) !== JSON.stringify(want)) {
          const bad =
            got.find((g) => !want.some((w) => w.from === g.from && w.to === g.to && w.block === g.block)) ??
            want.find((w) => !got.some((g) => g.from === w.from && g.to === w.to && g.block === w.block));
          const rule = bad ? ruleForRange(cell, bad.from, bad.to) : 'O-2';
          violations.push(`O-2/${rule} head=${head}: exp ${fmt(want)} got ${fmt(got)}`);
        }
      }

      // ---- Shift selections: O-2 with a non-empty selection --------------
      const heads = boundaryHeads(cell);
      const anchors = [0, Math.min(3, cell.doc.length)];
      for (const anchor of anchors) {
        for (const head of heads) {
          if (head === anchor) continue;
          setSel(view, { anchor, head });
          const got = extentsOf(view);
          const want = predictHidden(cell, { anchor, head });
          if (JSON.stringify(got) !== JSON.stringify(want)) {
            const bad =
              got.find((g) => !want.some((w) => w.from === g.from && w.to === g.to && w.block === g.block)) ??
              want.find((w) => !got.some((g) => g.from === w.from && g.to === w.to && g.block === w.block));
            const rule = bad ? ruleForRange(cell, bad.from, bad.to) : 'O-2';
            violations.push(
              `O-2/${rule} sel=[${anchor},${head}]: exp ${fmt(want)} got ${fmt(got)}`,
            );
          }
        }
      }

      // ---- O-5: revisiting positions reproduces the identical set --------
      const samples = heads.length ? heads : [0];
      for (const head of samples) {
        if (head < 0 || head > cell.doc.length) continue;
        setSel(view, { anchor: head, head });
        const again = JSON.stringify(extentsOf(view));
        if (again !== firstPass.get(head)) {
          violations.push(`O-5 head=${head}: revisit ${again} != first pass ${firstPass.get(head)}`);
        }
      }

      // ---- R-H1/R-H2: synthetic Left/Right, one position or atomic table -
      for (const start of heads) {
        for (const dir of [1, -1] as const) {
          setSel(view, { anchor: start, head: start });
          press(view, dir > 0 ? 'ArrowRight' : 'ArrowLeft');
          const got = view.state.selection.main.head;
          const want = predictHorizontal(cell, start, dir);
          if (got !== want) {
            const rule = predictAtomic(cell, { anchor: start, head: start }).length
              ? 'R-H2'
              : 'R-H1';
            violations.push(`${rule} head=${start} dir=${dir}: exp ${want} got ${got}`);
          }
        }
      }

      // ---- O-4 (atomic subset): the table is the only atomic range -------
      setSel(view, { anchor: 0, head: 0 });
      const atomicGot = probeAtomic(view).map(({ from, to }) => ({ from, to }));
      const atomicWant = predictAtomic(cell, { anchor: 0, head: 0 });
      if (JSON.stringify(atomicGot) !== JSON.stringify(atomicWant)) {
        violations.push(
          `O-4 atomic: exp ${JSON.stringify(atomicWant)} got ${JSON.stringify(atomicGot)}`,
        );
      }

      expect(violations, `${cell.id}\n${violations.slice(0, 12).join('\n')}`).toEqual([]);
    });
  }
});
