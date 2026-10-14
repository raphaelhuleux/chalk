#!/usr/bin/env node
/**
 * Geometric lane of the discovery matrix (see README.md).
 *
 * Drives the BUILT web bundle (web/dist) with Playwright — engine/device
 * lane via Tests/runner/lib/browser.mjs — and checks every composed cell
 * (compose.mjs) against rules.mjs, the code restatement of
 * docs/specs/2026-08-23-caret-and-reveal-semantics.md. Per cell:
 *
 *   - Right then Left walk in one in-page evaluate each, returning a
 *     per-step trace {head, hidden, o3}; heads chain through
 *     predictHorizontal (R-H1/R-H2), hidden through predictHidden (O-2,
 *     citing the construct's reveal rule), o3 is domLines==expectedLines.
 *   - Up/Down from every column of every probe line: topology from
 *     verticalTopology (R-V3/R-V4/R-V6/R-V7), stop landings exact
 *     (sameColumnOnLine), row landings measured as the nearest visible
 *     caret slot to the run's goal x on the target visual row — computed
 *     by scanning coordsAtPos over the row's slots, never by trusting
 *     posAtCoords — then applySnap (R-V5).
 *   - A goal-x run (R-V2): Down from a long top line across the construct
 *     to a long bottom line, final x must return to the captured goal x.
 *   - Home/End by coords bands (R-H3): the landing is the caret's visual
 *     row boundary, measured by a same-band scan.
 *   - Real page.mouse clicks: text positions at coordsAtPos centers (R-P1)
 *     and widget boxes with both halves for pills (R-P2).
 *   - A press-hold case on the tex textbf cell (R-P3).
 *   - Shift walks: Shift+Right across inline constructs (R-S1) and
 *     Shift+Down over blocks (R-S2), asserting O-2 with the live selection.
 *
 * Expectations come from rules.mjs or the slot scan ONLY. Failures print
 * `FAIL <cellId> <ruleId>` plus exp/got lines, tagged with the engine.
 * KNOWN_CELLS.txt (lines `cellId ruleId [@tag]`) turns known entries into
 * xfails; a listed entry that passes XPASS-fails the run.
 *
 *   pnpm test:matrix:geo [--no-build] [--filter substr] [--emit cellId]
 *   pnpm test:matrix:geo:webkit
 */
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { launchBrowser } from '../runner/lib/browser.mjs';
import { loadKnownFailures } from '../runner/lib/known-failures.mjs';
import { composeCells, VIEWPORTS } from './compose.mjs';
import {
  predictHidden,
  predictHorizontal,
  verticalTopology,
  stopLanding,
  applySnap,
  clickTargets,
  ruleForRange,
  lineOfPos,
} from './rules.mjs';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const dist = resolve(repoRoot, 'web/dist/editor.html');

const argv = process.argv.slice(2);
const flag = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : null;
};
const filter = flag('--filter');
const emitId = flag('--emit');

if (!argv.includes('--no-build')) {
  execFileSync(process.execPath, [resolve(repoRoot, 'web/build.mjs')], { stdio: 'inherit' });
}
if (!existsSync(dist)) {
  console.error(`missing ${dist} — run: pnpm web:build`);
  process.exit(1);
}

let cells = composeCells();
if (filter) cells = cells.filter((c) => c.id.includes(filter));

if (emitId) {
  const cell = composeCells().find((c) => c.id === emitId);
  if (!cell) {
    console.error(`--emit: no cell ${emitId}`);
    process.exit(1);
  }
  const body = '|' + cell.doc.replace(/\n$/, '');
  console.log('--- text');
  console.log(body);
  console.log('--- language');
  console.log(cell.language);
  if (cell.width !== 80) {
    console.log('--- width');
    console.log(String(cell.width));
  }
  console.log('--- keys');
  console.log('Down');
  console.log('--- expect');
  console.log(body);
  console.log('--- note');
  console.log(`Promoted from matrix cell ${emitId}; fill keys/expect by hand.`);
  process.exit(0);
}

if (!cells.length) {
  console.error(`no cells matched --filter ${filter}`);
  process.exit(1);
}

const kf = loadKnownFailures(resolve(repoRoot, 'Tests/matrix/KNOWN_CELLS.txt'), 'Tests/matrix/KNOWN_CELLS.txt');
const { browser, contextOptions, tag } = await launchBrowser();

// ---------------------------------------------------------------------------
//  Failure bookkeeping: one (cellId, ruleId) bucket per failure kind.
// ---------------------------------------------------------------------------

const failed = new Map(); // `${cellId} ${ruleId}` -> [detail lines]
const ranCells = new Set();
const perConstruct = new Map(); // construct -> {cells, fails, xfails}
let checks = 0;

function fail(cell, ruleId, detail) {
  const key = `${cell.id} ${ruleId}`;
  if (!failed.has(key)) failed.set(key, []);
  const list = failed.get(key);
  if (list.length < 6) list.push(detail);
}

// ---------------------------------------------------------------------------
//  In-page programs (serialized functions)
// ---------------------------------------------------------------------------

const PAGE_LIB = () => {
  const v = window.__chalkDebugView;
  const probe = window.__chalkDebugProbe;
  const contentLeft = () => v.contentDOM.getBoundingClientRect().left;
  const key = (name, shiftKey = false) =>
    v.contentDOM.dispatchEvent(
      new KeyboardEvent('keydown', { key: name, shiftKey, bubbles: true, cancelable: true }),
    );
  const caret = (pos) => {
    v.dispatch({ selection: { anchor: pos } });
    v.focus();
  };
  const hiddenExtents = () => probe.hidden().map((h) => ({ from: h.from, to: h.to, block: h.block }));
  /** Visible caret slots of one document line: positions not strictly inside
   *  a hidden range, with their x offset and vertical band. A soft-wrap
   *  boundary position renders on BOTH rows (assoc), so it contributes one
   *  slot per side when the sides land on different rows. */
  const slotsOf = (lineNo) => {
    const doc = v.state.doc;
    if (lineNo < 1 || lineNo > doc.lines) return [];
    const l = doc.line(lineNo);
    const hidden = probe.hidden();
    const out = [];
    for (let p = l.from; p <= l.to; p++) {
      if (hidden.some((h) => p > h.from && p < h.to)) continue;
      const c1 = v.coordsAtPos(p, 1);
      const c2 = v.coordsAtPos(p, -1);
      if (c1) out.push({ pos: p, x: c1.left - contentLeft(), top: c1.top, bottom: c1.bottom });
      if (c2 && (!c1 || Math.abs(c2.top - c1.top) > 2)) {
        out.push({ pos: p, x: c2.left - contentLeft(), top: c2.top, bottom: c2.bottom });
      }
    }
    return out;
  };
  /** Horizontal paint boxes of the rendered widgets on one line's row(s).
   *  A widget can paint wider than its caret slot (label pills with a title
   *  run), and CM6's landing resolution inside such a box zigzags between
   *  the replace's edges — so edge acceptance needs the true box. */
  const widgetBoxesOf = (lineNo) => {
    const doc = v.state.doc;
    if (lineNo < 1 || lineNo > doc.lines) return [];
    try {
      const l = doc.line(lineNo);
      const at = v.domAtPos(l.from);
      let el = at.node.nodeType === 1 ? at.node : at.node.parentElement;
      while (el && !el.classList?.contains('cm-line')) el = el.parentElement;
      if (!el) return [];
      const out = [];
      for (const w of el.querySelectorAll('*')) {
        const ce =
          w.getAttribute?.('contenteditable') === 'false' || w.contentEditable === 'false';
        if (!ce) continue;
        const b = w.getBoundingClientRect();
        if (b.width > 0) out.push({ l: b.left - contentLeft(), r: b.right - contentLeft() });
      }
      return out;
    } catch {
      return [];
    }
  };
  return { v, probe, contentLeft, key, caret, hiddenExtents, slotsOf, widgetBoxesOf };
};

// ---------------------------------------------------------------------------
//  Node-side helpers
// ---------------------------------------------------------------------------

function sameExtents(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}
function fmtH(list) {
  return list.map((h) => `[${h.from},${h.to})${h.block ? 'B' : ''}`).join(' ') || '(none)';
}

/** Group slots into visual rows (bands) and pick the row adjacent to
 *  `band` in direction `dir`. The 8px cluster threshold is deliberate: an
 *  inline-block widget's rect top sits a few px above its row's text top
 *  (see the CM6 widget layout notes), so a fine threshold would split one
 *  row into two. */
function adjacentRow(slots, band, dir) {
  const rows = [];
  for (const s of [...slots].sort((x, y) => x.top - y.top || x.pos - y.pos)) {
    const row = rows.find((r) => Math.abs(r.top - s.top) < 8);
    if (row) row.slots.push(s);
    else rows.push({ top: s.top, slots: [s] });
  }
  const candidates = rows.filter((r) => (dir > 0 ? r.top > band.top + 8 : r.top < band.top - 8));
  if (!candidates.length) return null;
  candidates.sort((a, b) => Math.abs(a.top - band.top) - Math.abs(b.top - band.top));
  return candidates[0].slots;
}

// ---------------------------------------------------------------------------
//  Per-cell checks
// ---------------------------------------------------------------------------

async function initCell(page, cell, metricsRef) {
  await page.evaluate((msg) => window.__chalkHost.receive(msg), {
    type: 'init',
    text: cell.doc,
    language: cell.language,
  });
  await page.waitForSelector('.cm-content');
  await page.waitForTimeout(250);
  if (!metricsRef.value) {
    metricsRef.value = await page.evaluate(() => {
      const content = document.querySelector('.cm-content');
      const cs = getComputedStyle(content);
      const probeEl = document.createElement('span');
      probeEl.style.cssText = `position:absolute;visibility:hidden;white-space:pre;font:${cs.font};font-family:${cs.fontFamily};font-size:${cs.fontSize};font-variant-ligatures:none`;
      document.body.appendChild(probeEl);
      const advance = (s) => {
        probeEl.textContent = s.repeat(100);
        return probeEl.getBoundingClientRect().width / 100;
      };
      const charWidth = advance('x');
      const iW = advance('i');
      const wW = advance('W');
      probeEl.remove();
      const line = document.querySelector('.cm-line');
      const ls = getComputedStyle(line);
      return {
        charWidth,
        mono: Math.abs(iW - wW) < 0.01,
        padLeft: parseFloat(ls.paddingLeft) || 0,
        padRight: parseFloat(ls.paddingRight) || 0,
      };
    });
    if (!metricsRef.value.mono) throw new Error('writing surface is not monospaced in this engine');
  }
  const m = metricsRef.value;
  const px = cell.width * m.charWidth + m.padLeft + m.padRight + 0.5;
  await page.evaluate((width) => {
    let el = document.getElementById('matrix-width');
    if (!el) {
      el = document.createElement('style');
      el.id = 'matrix-width';
      document.head.appendChild(el);
    }
    el.textContent = `.editor-host .cm-content { max-width: ${width}px !important; width: ${width}px !important; }`;
    window.__chalkDebugView.requestMeasure();
  }, px);
  await page.waitForTimeout(150);
}

async function checkWalks(page, cell) {
  for (const dir of [1, -1]) {
    const trace = await page.evaluate(
      ([d, docLen, libSrc]) => {
        const lib = eval(`(${libSrc})`)();
        lib.caret(d > 0 ? 0 : docLen);
        const steps = [];
        let guard = 0;
        let last = d > 0 ? 0 : docLen;
        while (guard++ < docLen + 30) {
          lib.key(d > 0 ? 'ArrowRight' : 'ArrowLeft');
          const snap = lib.probe.snapshot();
          const o3 =
            JSON.stringify(snap.domLines) === JSON.stringify(lib.probe.expectedLines());
          steps.push({
            head: snap.head,
            hidden: snap.hidden.map((h) => ({ from: h.from, to: h.to, block: h.block })),
            o3,
          });
          if (snap.head === last) break;
          last = snap.head;
          if (d > 0 ? snap.head >= docLen : snap.head <= 0) break;
        }
        return steps;
      },
      [dir, cell.doc.length, PAGE_LIB.toString()],
    );
    let head = dir > 0 ? 0 : cell.doc.length;
    for (const step of trace) {
      checks++;
      const want = predictHorizontal(cell, head, dir, { anchor: head, head });
      if (step.head !== want && step.head !== head) {
        fail(cell, 'R-H1', `walk dir=${dir} from ${head}: exp ${want} got ${step.head}`);
      } else if (step.head !== want) {
        // stuck caret before the doc edge
        if (dir > 0 ? head < cell.doc.length : head > 0) {
          fail(cell, 'R-H1', `walk dir=${dir} stuck at ${head} (exp ${want})`);
        }
      }
      const sel = { anchor: step.head, head: step.head };
      const wantHidden = predictHidden(cell, sel);
      if (!sameExtents(step.hidden, wantHidden)) {
        const bad =
          step.hidden.find((g) => !wantHidden.some((w) => w.from === g.from && w.to === g.to && w.block === g.block)) ??
          wantHidden.find((w) => !step.hidden.some((g) => g.from === w.from && g.to === w.to && g.block === w.block));
        const rule = bad ? ruleForRange(cell, bad.from, bad.to) : 'O-2';
        fail(cell, rule, `walk head=${step.head}: exp ${fmtH(wantHidden)} got ${fmtH(step.hidden)}`);
      }
      if (!step.o3) fail(cell, 'O-3', `walk head=${step.head}: domLines != expectedLines`);
      head = step.head;
      if (step.head === want && (dir > 0 ? head >= cell.doc.length : head <= 0)) break;
    }
  }
}

function probeLines(cell) {
  const lineCount = cell.doc.split('\n').length;
  const starts = [0];
  for (let i = 0; i < cell.doc.length; i++) if (cell.doc[i] === '\n') starts.push(i + 1);
  const out = [];
  // Lines strictly inside a table's lezer node are skipped (the caret never
  // legitimately rests there and the widget's cells own their geometry).
  const tableLines = new Set();
  for (const inst of cell.instances) {
    if (inst.kind !== 'table') continue;
    const callout = cell.instances.find((i) => i.kind === 'callout' && i.closeLine === inst.toLine + 1);
    const end = callout ? inst.toLine + 1 : inst.toLine;
    for (let n = inst.fromLine; n <= end; n++) tableLines.add(n);
  }
  for (let n = 1; n <= lineCount; n++) {
    if (tableLines.has(n)) continue;
    const from = starts[n - 1];
    const to = n < starts.length ? starts[n] - 1 : cell.doc.length;
    out.push({ n, from, to, len: to - from });
  }
  return out;
}

async function checkVertical(page, cell) {
  const lines = probeLines(cell);
  const lineCount = cell.doc.split('\n').length;
  for (const line of lines) {
    for (const dir of [1, -1]) {
      if (line.n + dir < 1 || line.n + dir > lineCount) continue;
      const trace = await page.evaluate(
        ([lineNo, d, libSrc]) => {
          const lib = eval(`(${libSrc})`)();
          const doc = lib.v.state.doc;
          const l = doc.line(lineNo);
          const results = [];
          for (let col = 0; col <= l.length; col++) {
            const pos = l.from + col;
            lib.caret(pos);
            const hidden = lib.probe.hidden();
            if (hidden.some((h) => pos > h.from && pos < h.to)) {
              results.push({ pos, skipped: 'inside-hidden' });
              continue;
            }
            const sel = lib.v.state.selection.main;
            const c = lib.v.coordsAtPos(sel.head, sel.assoc || 1);
            if (!c) {
              results.push({ pos, skipped: 'no-coords' });
              continue;
            }
            // A caret dispatched EXACTLY onto a soft-wrap boundary is
            // assoc-ambiguous (it renders on one row, the engine may move
            // from the other); the wrap-boundary fixtures own that edge.
            const cBack = lib.v.coordsAtPos(pos, -1);
            if (cBack && Math.abs(cBack.top - c.top) > 2) {
              results.push({ pos, skipped: 'wrap-boundary' });
              continue;
            }
            const goalX = c.left - lib.contentLeft();
            const band = { top: c.top, bottom: c.bottom };
            let sameLineRow = false;
            try {
              const moved = lib.v.moveVertically(sel, d > 0);
              sameLineRow =
                moved.head !== sel.head && doc.lineAt(moved.head).number === lineNo;
            } catch {
              results.push({ pos, skipped: 'no-layout' });
              continue;
            }
            // Pre-press slots of the line, its neighbour, and one beyond:
            // a collapsed fence merges the line past the target into the
            // target's visual row, so its edge positions are landings too.
            const slotsSame = lib.slotsOf(lineNo);
            const slotsNext = lib.slotsOf(lineNo + d);
            const slotsBeyond = lib.slotsOf(lineNo + 2 * d);
            const widgetBoxes = [
              ...lib.widgetBoxesOf(lineNo),
              ...lib.widgetBoxesOf(lineNo + d),
            ];
            lib.key(d > 0 ? 'ArrowDown' : 'ArrowUp');
            const got = lib.v.state.selection.main.head;
            results.push({
              pos,
              goalX,
              band,
              sameLineRow,
              slotsSame,
              slotsNext,
              slotsBeyond,
              widgetBoxes,
              got,
            });
          }
          return results;
        },
        [line.n, dir, PAGE_LIB.toString()],
      );
      for (const r of trace) {
        if (r.skipped) continue;
        checks++;
        const sel = { anchor: r.pos, head: r.pos };
        const topo = verticalTopology(cell, r.pos, dir, sel, { sameLineRow: r.sameLineRow });
        if (topo.kind === 'edge') continue;
        if (topo.kind === 'stop') {
          const want = stopLanding(cell, r.pos, topo.targetLine);
          if (r.got !== want) {
            fail(cell, topo.ruleId, `line ${line.n} col ${r.pos - line.from} dir=${dir}: stop exp ${want} got ${r.got}`);
          }
          continue;
        }
        if (topo.kind === 'table') {
          if (r.got !== topo.pos) {
            fail(cell, topo.ruleId, `line ${line.n} col ${r.pos - line.from} dir=${dir}: table-cross exp ${topo.pos} got ${r.got}`);
          }
          continue;
        }
        // kind === 'row': measured landing. The candidate row is chosen from
        // the union of nearby lines' slots, so a collapsed fence's merged
        // edge positions and wrap-boundary duals are all candidates.
        const allSlots = [...r.slotsSame, ...r.slotsNext, ...r.slotsBeyond];
        const row = adjacentRow(allSlots, r.band, dir);
        if (!row || !row.length) continue; // no measurable target row
        let best = row[0];
        for (const s of row) if (Math.abs(s.x - r.goalX) < Math.abs(best.x - r.goalX)) best = s;
        const expected = applySnap(cell, sel, best.pos);
        if (r.got === expected) continue;
        const gotEntries = row.filter((s) => s.pos === r.got);
        if (!gotEntries.length) {
          // A landing strictly inside a hidden range is a snap-contract
          // violation on tex (R-V5), a row violation otherwise.
          const insideHidden = predictHidden(cell, sel).some(
            (h) => r.got > h.from && r.got < h.to,
          );
          fail(
            cell,
            insideHidden && cell.language === 'tex' ? 'R-V5' : topo.ruleId,
            `line ${line.n} col ${r.pos - line.from} dir=${dir}: landing left the target visual row: exp ${expected} got ${r.got}`,
          );
          continue;
        }
        const minDist = Math.abs(best.x - r.goalX);
        const expSlot = row.find((s) => s.pos === expected) ?? best;
        let ok = false;
        if (applySnap(cell, sel, r.got) === r.got) {
          for (const g of gotEntries) {
            // (a) Sub-pixel tie: the got slot is as close to the goal x as
            // the minimum, or sits at the same pre-press x as the expected
            // slot (zero-width hidden ranges make several positions share
            // one caret x — the engine may pick the revealing side).
            if (Math.abs(g.x - r.goalX) <= minDist + 1.5 || Math.abs(g.x - expSlot.x) <= 1.5) {
              ok = true;
              break;
            }
          }
          // (b) Widget-interior resolution: a goal x INSIDE a rendered
          // widget's paint box legitimately resolves to either edge of its
          // hidden range (the engine's DOM bisection zigzags inside a
          // multi-run widget, and a label widget paints wider than its
          // caret slot).
          if (!ok) {
            const hidden = predictHidden(cell, sel);
            const isEdge = hidden.some((h) => r.got === h.from || r.got === h.to);
            ok =
              isEdge &&
              r.widgetBoxes.some((b) => r.goalX >= b.l - 1.5 && r.goalX <= b.r + 1.5);
          }
        }
        if (ok) continue;
        const ruleId = expected === best.pos ? topo.ruleId : 'R-V5';
        fail(
          cell,
          ruleId,
          `line ${line.n} col ${r.pos - line.from} dir=${dir}: row-landing exp ${expected} (raw ${best.pos}, goalX ${r.goalX.toFixed(1)}) got ${r.got}`,
        );
      }
    }
  }
}

async function checkGoalRun(page, cell) {
  // R-V2: a long top line, the construct, a long bottom line; if the cell
  // has that shape, Down from column 18 must return to the same x.
  const lines = probeLines(cell);
  const long = lines.filter((l) => l.len >= 24);
  if (long.length < 2) return;
  const start = long[0];
  const end = long[long.length - 1];
  if (end.n <= start.n + 1) return;
  checks++;
  const res = await page.evaluate(
    ([startPos, endLine, maxPresses, libSrc]) => {
      const lib = eval(`(${libSrc})`)();
      const doc = lib.v.state.doc;
      lib.caret(startPos);
      const sel0 = lib.v.state.selection.main;
      const c0 = lib.v.coordsAtPos(sel0.head, sel0.assoc || 1);
      if (!c0) return { skipped: true };
      const startX = c0.left - lib.contentLeft();
      let presses = 0;
      while (presses++ < maxPresses) {
        lib.key('ArrowDown');
        if (doc.lineAt(lib.v.state.selection.main.head).number >= endLine) break;
      }
      const head = lib.v.state.selection.main.head;
      const c1 = lib.v.coordsAtPos(head, 1) || lib.v.coordsAtPos(head, -1);
      return {
        startX,
        endX: c1 ? c1.left - lib.contentLeft() : null,
        endLineGot: doc.lineAt(head).number,
        presses,
      };
    },
    [start.from + 18, end.n, lineCountOf(cell) + 10, PAGE_LIB.toString()],
  );
  if (res.skipped) return;
  if (res.endLineGot !== end.n) {
    fail(cell, 'R-V1', `goal-run: expected to reach line ${end.n}, got line ${res.endLineGot} after ${res.presses} presses`);
    return;
  }
  const m = await page.evaluate(() => window.__chalkDebugView.defaultCharacterWidth);
  if (res.endX === null || Math.abs(res.endX - res.startX) > m * 0.6) {
    fail(cell, 'R-V2', `goal-run: start x ${res.startX.toFixed(1)} end x ${res.endX?.toFixed(1)} (tolerance ${(m * 0.6).toFixed(1)})`);
  }
}

function lineCountOf(cell) {
  return cell.doc.split('\n').length;
}

async function checkHomeEnd(page, cell) {
  // R-H3 probes: a few caret rests on lines without leading whitespace.
  const lines = probeLines(cell).filter(
    (l) => l.len > 0 && !/^\s/.test(cell.doc.slice(l.from, l.from + 1)),
  );
  const probes = [];
  for (const l of lines.slice(0, 5)) probes.push(l.from + Math.min(4, l.len));
  const res = await page.evaluate(
    ([positions, libSrc]) => {
      const lib = eval(`(${libSrc})`)();
      const doc = lib.v.state.doc;
      const out = [];
      for (const pos of positions) {
        for (const forward of [true, false]) {
          lib.caret(pos);
          const c0 = lib.v.coordsAtPos(pos, forward ? -1 : 1);
          if (!c0) continue;
          const line = doc.lineAt(pos);
          // Same-band boundary scan (position -> coords, the reliable
          // direction), mirroring rowBoundaryPos. The xs are recorded
          // PRE-press: a boundary landing inside a reveal window reflows
          // the line, so post-press coords cannot rank the landing.
          const band = { top: c0.top, bottom: c0.bottom };
          const bandX = {};
          const onBand = (p) => {
            const c = lib.v.coordsAtPos(p, forward ? -1 : 1);
            if (!c || !(c.top < band.bottom && band.top < c.bottom)) return false;
            bandX[p] = c.left;
            return true;
          };
          // A collapsed fence merges neighbouring lines into this visual
          // row, so the scan runs up to two document lines past the caret's
          // own; the band check keeps real other rows out.
          const lastLine = Math.min(doc.lines, line.number + 2);
          const firstLine = Math.max(1, line.number - 2);
          let boundary = pos;
          if (forward) {
            for (let p = pos; p <= doc.line(lastLine).to; p++) if (onBand(p)) boundary = p;
          } else {
            for (let p = pos; p >= doc.line(firstLine).from; p--) if (onBand(p)) boundary = p;
          }
          lib.key(forward ? 'End' : 'Home');
          const got = lib.v.state.selection.main.head;
          out.push({
            pos,
            forward,
            boundary,
            got,
            lineFrom: line.from,
            lineTo: line.to,
            boundaryX: bandX[boundary] ?? null,
            gotX: bandX[got] ?? null,
          });
        }
      }
      return out;
    },
    [probes, PAGE_LIB.toString()],
  );
  for (const r of res) {
    checks++;
    if (r.gotX === null) {
      fail(cell, 'R-H3', `${r.forward ? 'End' : 'Home'} from ${r.pos}: left the visual row (got ${r.got})`);
      continue;
    }
    // Compare by caret x, not position: a zero-width hidden run at the row
    // edge makes several positions share one visual boundary, and any of
    // them is the boundary the user sees.
    const sameX =
      r.boundaryX !== null && r.gotX !== null && Math.abs(r.gotX - r.boundaryX) <= 1.5;
    if (r.got !== r.boundary && !sameX) {
      fail(
        cell,
        'R-H3',
        `${r.forward ? 'End' : 'Home'} from ${r.pos}: exp row boundary ${r.boundary} got ${r.got}`,
      );
    }
  }
}

async function checkClicks(page, cell) {
  // R-P1 on a few plain-prose positions of the first park line.
  const firstLine = probeLines(cell).find((l) => cell.doc.slice(l.from, l.to).startsWith('park'));
  if (firstLine) {
    for (const col of [2, 11, 24]) {
      if (col > firstLine.len - 1) continue;
      checks++;
      const pos = firstLine.from + col;
      await page.evaluate((p) => {
        const v = window.__chalkDebugView;
        v.dispatch({ selection: { anchor: 0 } });
        v.focus();
      }, pos);
      const rect = await page.evaluate((p) => {
        const c = window.__chalkDebugView.coordsAtPos(p, 1);
        return c ? { left: c.left, top: c.top, bottom: c.bottom } : null;
      }, pos);
      if (!rect) continue;
      await page.mouse.click(rect.left + 1, (rect.top + rect.bottom) / 2);
      await page.waitForTimeout(60);
      const got = await page.evaluate(() => window.__chalkDebugView.state.selection.main.head);
      if (got !== pos) fail(cell, 'R-P1', `click at slot ${pos}: caret got ${got}`);
    }
  }

  // R-P2 widget clicks (center; pills also right edge).
  for (const target of clickTargets(cell)) {
    for (const side of target.selector.includes('pill') ? ['center', 'right'] : ['center']) {
      checks++;
      await page.evaluate(() => {
        const v = window.__chalkDebugView;
        v.dispatch({ selection: { anchor: 0 } });
        v.focus();
      });
      await page.waitForTimeout(120);
      const box = await page
        .locator(target.selector)
        .nth(target.nth)
        .boundingBox()
        .catch(() => null);
      if (!box) {
        fail(cell, target.rule, `${target.selector}: widget not rendered`);
        continue;
      }
      const x = side === 'right' ? box.x + box.width - 2 : box.x + box.width / 2;
      await page.mouse.click(x, box.y + box.height / 2);
      await page.waitForTimeout(150);
      const st = await page.evaluate(() => {
        const v = window.__chalkDebugView;
        const m = v.state.selection.main;
        return {
          head: m.head,
          empty: m.empty,
          hidden: window.__chalkDebugProbe.hidden().map((h) => ({ from: h.from, to: h.to, block: h.block })),
        };
      });
      if (!st.empty || st.head !== target.land) {
        fail(cell, target.rule, `${target.selector} ${side}: exp caret ${target.land} got ${st.empty ? '' : 'selection '}${st.head}`);
        continue;
      }
      const want = predictHidden(cell, { anchor: st.head, head: st.head });
      if (!sameExtents(st.hidden, want)) {
        fail(cell, target.rule, `${target.selector} ${side}: post-click hidden exp ${fmtH(want)} got ${fmtH(st.hidden)}`);
      }
    }
  }
}

async function checkPressHold(page, cell) {
  // R-P3, tex only, on the textbf mid cell: geometry frozen while pressed.
  checks++;
  await page.evaluate(() => {
    const v = window.__chalkDebugView;
    v.dispatch({ selection: { anchor: 0 } });
    v.focus();
  });
  await page.waitForTimeout(120);
  const r = await page.evaluate(() => {
    const walker = document.createTreeWalker(document.querySelector('.cm-content'), NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      const n = walker.currentNode;
      const i = n.textContent.indexOf('bold');
      if (i >= 0) {
        const range = document.createRange();
        range.setStart(n, i);
        range.setEnd(n, i + 4);
        const b = range.getBoundingClientRect();
        return { x: b.x + b.width / 2, y: b.y + b.height / 2 };
      }
    }
    return null;
  });
  if (!r) {
    fail(cell, 'R-P3', 'press-hold: target text not found');
    return;
  }
  await page.mouse.move(r.x, r.y);
  await page.mouse.down();
  await page.waitForTimeout(90);
  const whilePressed = await page.evaluate(() => document.querySelector('.cm-content').innerText.includes('\\textbf{'));
  await page.mouse.up();
  await page.waitForTimeout(90);
  const afterRelease = await page.evaluate(() => document.querySelector('.cm-content').innerText.includes('\\textbf{bold}'));
  if (whilePressed) fail(cell, 'R-P3', 'revealed while the button was still down');
  if (!afterRelease) fail(cell, 'R-P3', 'not revealed on release');
}

async function checkShiftWalks(page, cell) {
  // R-S1: Shift+Right across the first inline instance; the construct must
  // stay concealed under the growing selection (O-2 with a live range).
  const inline = cell.instances.find((i) =>
    ['inline-math', 'command', 'pill', 'href', 'marker-pair', 'whole-replace'].includes(i.kind),
  );
  if (inline) {
    const from =
      inline.from ?? inline.cmdFrom ?? inline.nodeFrom;
    const to = (inline.to ?? (inline.argTo != null ? inline.argTo + 1 : null) ?? (inline.textTo != null ? inline.textTo + 1 : null) ?? inline.nodeTo);
    const anchor = Math.max(0, from - 2);
    const presses = Math.min(to - anchor + 3, 40);
    const trace = await page.evaluate(
      ([a, n, libSrc]) => {
        const lib = eval(`(${libSrc})`)();
        lib.caret(a);
        const steps = [];
        for (let i = 0; i < n; i++) {
          lib.key('ArrowRight', true);
          const m = lib.v.state.selection.main;
          steps.push({ anchor: m.anchor, head: m.head, hidden: lib.hiddenExtents() });
        }
        return steps;
      },
      [anchor, presses, PAGE_LIB.toString()],
    );
    let head = anchor;
    for (const step of trace) {
      checks++;
      const want = predictHorizontal(cell, head, 1, { anchor, head });
      if (step.head !== want || step.anchor !== anchor) {
        fail(cell, 'R-S1', `shift-walk from ${head}: exp anchor ${anchor} head ${want}, got anchor ${step.anchor} head ${step.head}`);
      }
      const wantHidden = predictHidden(cell, { anchor: step.anchor, head: step.head });
      if (!sameExtents(step.hidden, wantHidden)) {
        fail(cell, 'R-S1', `shift-walk sel [${step.anchor},${step.head}]: exp ${fmtH(wantHidden)} got ${fmtH(step.hidden)}`);
      }
      head = step.head;
    }
  }

  // R-S2: Shift+Down over a display block reveals it while the head is on
  // its lines (line-window includes selections).
  const display = cell.instances.find((i) => i.kind === 'display-math');
  if (display && lineOfPos(cell, display.from) > 1) {
    const trace = await page.evaluate(
      ([startPos, n, libSrc]) => {
        const lib = eval(`(${libSrc})`)();
        lib.caret(startPos);
        const steps = [];
        for (let i = 0; i < n; i++) {
          lib.key('ArrowDown', true);
          const m = lib.v.state.selection.main;
          steps.push({ anchor: m.anchor, head: m.head, hidden: lib.hiddenExtents() });
        }
        return steps;
      },
      [Math.max(0, display.from - 8), 3, PAGE_LIB.toString()],
    );
    for (const step of trace) {
      checks++;
      const wantHidden = predictHidden(cell, { anchor: step.anchor, head: step.head });
      if (!sameExtents(step.hidden, wantHidden)) {
        const bad =
          step.hidden.find((g) => !wantHidden.some((w) => w.from === g.from && w.to === g.to)) ??
          wantHidden.find((w) => !step.hidden.some((g) => g.from === w.from && g.to === w.to));
        const rule = bad ? ruleForRange(cell, bad.from, bad.to) : 'R-S2';
        fail(cell, 'R-S2', `shift-down sel [${step.anchor},${step.head}] (${rule}): exp ${fmtH(wantHidden)} got ${fmtH(step.hidden)}`);
      }
    }
  }
}

// ---------------------------------------------------------------------------
//  Main
// ---------------------------------------------------------------------------

// Assets resolve for real: a stub native bridge (the run.mjs idiom — see
// `md: image path completion over the host bridge`) answers `resolve-asset`
// with a data URL of test-docs/figures/tiny.png, so an \includegraphics /
// ![](…) cell renders an actual image instead of a zero-box img and the
// matrix tests the case users see. Installed before the bundle boots
// (native-host binds the bridge at module load).
const tinyPng = `data:image/png;base64,${readFileSync(
  resolve(repoRoot, 'test-docs/figures/tiny.png'),
).toString('base64')}`;

const pages = new Map(); // viewport name -> {page, metricsRef}
async function pageFor(viewportName) {
  if (pages.has(viewportName)) return pages.get(viewportName);
  const page = await browser.newPage({ ...contextOptions, viewport: VIEWPORTS[viewportName] });
  page.on('pageerror', (e) => {
    console.log(`[${tag}] PAGE ERROR: ${e}`);
  });
  await page.addInitScript((assetUrl) => {
    window.webkit = {
      messageHandlers: {
        chalkHost: {
          postMessage(m) {
            if (m.type === 'resolve-asset') {
              setTimeout(() => window.__chalkHost.resolveAssetReply(m.id, assetUrl), 5);
            }
            if (m.type === 'list-files') {
              setTimeout(() => window.__chalkHost.listFilesReply(m.id, []), 5);
            }
            if (m.type === 'read-text') {
              setTimeout(() => window.__chalkHost.readTextReply(m.id, null), 5);
            }
          },
        },
      },
    };
  }, tinyPng);
  await page.goto(pathToFileURL(dist).href + '?debug');
  await page.waitForFunction('() => window.__chalkHost !== undefined');
  const entry = { page, metricsRef: { value: null } };
  pages.set(viewportName, entry);
  return entry;
}

const t0 = Date.now();
for (const cell of cells) {
  const { page, metricsRef } = await pageFor(cell.viewport);
  process.stdout.write(`[${tag}] ${cell.id} ... `);
  const before = failed.size;
  try {
    await initCell(page, cell, metricsRef);
    await checkWalks(page, cell);
    await checkVertical(page, cell);
    await checkGoalRun(page, cell);
    await checkHomeEnd(page, cell);
    await checkClicks(page, cell);
    if (cell.id === 'tex/textbf/mid/w80/desktop') await checkPressHold(page, cell);
    await checkShiftWalks(page, cell);
  } catch (e) {
    fail(cell, 'HARNESS', String(e && e.message ? e.message : e));
  }
  ranCells.add(cell.id);
  const cellFails = [...failed.keys()].filter((k) => k.startsWith(`${cell.id} `));
  const newFails = failed.size - before;
  const stat = perConstruct.get(`${cell.language}/${cell.construct}`) ?? { cells: 0, fails: 0, xfails: 0 };
  stat.cells++;
  let xfailHere = 0;
  for (const key of cellFails) {
    const ruleId = key.slice(cell.id.length + 1);
    if (kf.isKnown(`${cell.id} ${ruleId}`, tag)) xfailHere++;
  }
  stat.fails += cellFails.length - xfailHere;
  stat.xfails += xfailHere;
  perConstruct.set(`${cell.language}/${cell.construct}`, stat);
  console.log(newFails === 0 ? 'ok' : `${newFails} rule(s) red`);
}

// ---------------------------------------------------------------------------
//  Report
// ---------------------------------------------------------------------------

let hardFailures = 0;
let xfails = 0;
for (const [key, details] of failed) {
  const [cellId, ruleId] = [key.slice(0, key.lastIndexOf(' ')), key.slice(key.lastIndexOf(' ') + 1)];
  if (kf.isKnown(key, tag)) {
    console.log(`[${tag}] xfail ${cellId} ${ruleId}`);
    xfails++;
    continue;
  }
  hardFailures++;
  console.log(`[${tag}] FAIL ${cellId} ${ruleId}`);
  for (const d of details) console.log(`[${tag}]   ${d}`);
}

// XPASS: known entries that ran and did not fail.
let xpass = 0;
for (const cellId of ranCells) {
  for (const ruleId of ['O-2', 'O-3', 'R-H1', 'R-H2', 'R-H3', 'R-V1', 'R-V2', 'R-V3', 'R-V4', 'R-V5', 'R-V6', 'R-V7', 'R-P1', 'R-P2', 'R-P3', 'R-S1', 'R-S2', 'R-T1', 'R-T2', 'R-T3', 'R-T4', 'R-T5', 'R-T6', 'R-T7', 'R-T8', 'R-T9', 'R-M1', 'R-M2', 'R-M3', 'R-M4', 'R-M5', 'R-M6', 'R-M7', 'R-M8', 'R-M9']) {
    const key = `${cellId} ${ruleId}`;
    if (kf.isKnown(key, tag) && !failed.has(key)) {
      console.log(`[${tag}] XPASS ${key}  (${kf.formatUnexpectedPass(key, tag)})`);
      xpass++;
    }
  }
}

console.log(`\n[${tag}] per-construct summary:`);
console.log(`[${tag}]   ${'construct'.padEnd(28)} cells  red  xfail`);
for (const [name, s] of [...perConstruct.entries()].sort()) {
  console.log(`[${tag}]   ${name.padEnd(28)} ${String(s.cells).padStart(5)} ${String(s.fails).padStart(4)} ${String(s.xfails).padStart(6)}`);
}
const secs = ((Date.now() - t0) / 1000).toFixed(1);
console.log(
  `\n[${tag}] ${ranCells.size} cells, ${checks} checks, ${hardFailures} failing rule buckets, ${xfails} xfail, ${xpass} XPASS, ${secs}s`,
);

await browser.close();
process.exit(hardFailures + xpass > 0 ? 1 : 0);
