/**
 * rules.mjs — the ONLY code restatement of the caret/reveal spec
 * (docs/specs/2026-08-23-caret-and-reveal-semantics.md).
 *
 * Every function is pure over a composed cell (compose.mjs) plus a selection
 * {anchor, head}; nothing here consults the engine. The lanes compare the
 * engine's observable state (via debug-probe) against these predictions and
 * cite the returned rule IDs on failure.
 *
 * If a prediction disagrees with the engine, the decision tree is:
 * engine bug -> Tests/matrix/KNOWN_CELLS.txt + Tests/matrix/FINDINGS.md;
 * rules bug -> fix HERE to match the spec; spec bug -> fix the spec and say
 * so in the commit. Never edit a prediction to match observed output.
 */

// ---------------------------------------------------------------------------
//  Document geometry helpers (pure, over cell.doc)
// ---------------------------------------------------------------------------

const lineCache = new WeakMap();

function lines(cell) {
  let l = lineCache.get(cell);
  if (l) return l;
  const starts = [0];
  for (let i = 0; i < cell.doc.length; i++) if (cell.doc[i] === '\n') starts.push(i + 1);
  // cell.doc ends with '\n' (composer) except deliberately unclosed tails;
  // starts[k] is the 0-based offset of 1-based line k+1.
  l = {
    starts,
    count: starts.length,
    from: (n) => starts[n - 1],
    to: (n) => (n < starts.length ? starts[n] - 1 : cell.doc.length),
  };
  lineCache.set(cell, l);
  return l;
}

export function lineOfPos(cell, pos) {
  const { starts } = lines(cell);
  let lo = 0;
  let hi = starts.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (starts[mid] <= pos) lo = mid;
    else hi = mid - 1;
  }
  return lo + 1;
}

function empty(sel) {
  return sel.anchor === sel.head;
}

/** A selection end strictly inside [from, to): nowhere to sit once replaced. */
function strandedIn(sel, from, to) {
  const lo = Math.min(sel.anchor, sel.head);
  const hi = Math.max(sel.anchor, sel.head);
  return (lo > from && lo < to) || (hi > from && hi < to);
}

/** Spec "selection-on-line" over the line span [from, to] whose construct
 *  hides [hideFrom, hideTo]: an empty caret on the span, a selection anchored
 *  on it, or a selection end stranded inside the hidden range. */
function selOnRange(sel, from, to, hideFrom = from, hideTo = to) {
  if (empty(sel)) return sel.head >= from && sel.head <= to;
  if (sel.anchor >= from && sel.anchor <= to) return true;
  return strandedIn(sel, hideFrom, hideTo);
}

/** selOnRange for line `n`; `hideFrom` defaults to the line start (a widget
 *  replacing the line text), pass the previous line's end for a collapsed row. */
function selOnLine(cell, sel, n, hideFrom) {
  const L = lines(cell);
  return selOnRange(sel, L.from(n), L.to(n), hideFrom ?? L.from(n), L.to(n));
}

/** Spec "char-window [from, to)": empty caret with head inside. */
function revealChar(sel, from, to) {
  return empty(sel) && sel.head >= from && sel.head < to;
}

/** Spec R-T2/R-M2 blockFrom: snap to the line start over leading whitespace. */
function blockFrom(cell, from) {
  const L = lines(cell);
  const start = L.from(lineOfPos(cell, from));
  if (start === from) return from;
  return cell.doc.slice(start, from).trim() === '' ? start : from;
}

// ---------------------------------------------------------------------------
//  Per-instance reveal + hidden prediction
// ---------------------------------------------------------------------------

/** Whether an instance is revealed under `sel` (flags: {override}). */
export function instanceRevealed(cell, inst, sel, flags = {}) {
  const override = flags.override === true && cell.language === 'tex';
  switch (inst.kind) {
    case 'inline-math':
      return !override && revealChar(sel, inst.from, inst.to);
    case 'display-math': {
      // Line-window, selection-on-line style (R-S2); exempt from the conceal
      // override.
      const L = lines(cell);
      const first = L.from(lineOfPos(cell, inst.from));
      const last = L.to(lineOfPos(cell, inst.to - 1));
      return selOnRange(sel, first, last, blockFrom(cell, inst.from), inst.to);
    }
    case 'display-unclosed':
      return true; // renders nothing: always raw
    case 'command':
      return !override && revealChar(sel, inst.cmdFrom, inst.argTo + 1);
    case 'pill':
      return !override && revealChar(sel, inst.cmdFrom, inst.argTo + 1);
    case 'href':
      return !override && revealChar(sel, inst.cmdFrom, inst.textTo + 1);
    case 'whole-replace':
      return revealChar(sel, inst.from, inst.to);
    case 'marker-pair':
      return revealChar(sel, inst.nodeFrom, inst.nodeTo);
    case 'heading-attr':
      // `+1` like the pills (R-T4): the attribute ENDS THE LINE, so the caret
      // position after `}` is the only one past it. Excluding it left the id
      // half-editable — the caret could reach the end and the source vanished
      // exactly when it got there.
      return revealChar(sel, inst.nodeFrom, inst.nodeTo + 1);
    case 'table':
      return false; // the table never reveals
    case 'callout':
    case 'frame':
    case 'list':
    case 'none':
      return false; // per-part logic below; no whole-construct reveal
    default:
      throw new Error(`rules: unknown kind ${inst.kind}`);
  }
}

/** List close/open fence suppression: the fence's merge host (the previous
 *  non-fence line) starts inside a display-math extent, so the LIST emits no
 *  hide — the math widget absorbs the fence instead (R-T7 note). Computed
 *  from the scan geometry alone, so it holds whether or not the math is
 *  currently revealed (a revealed math leaves the fence fully visible). */
function listFenceConsumedByMath(cell, fenceLine) {
  const L = lines(cell);
  const closeFences = new Set(
    cell.instances.filter((i) => i.kind === 'list' && i.items.length > 0).map((i) => i.closeLine),
  );
  let n = fenceLine - 1;
  while (n >= 1 && closeFences.has(n)) n--;
  if (n < 1) return false;
  const hostFrom = L.from(n);
  return cell.instances.some(
    (i) => i.kind === 'display-math' && i.from <= hostFrom && hostFrom < i.to,
  );
}

/** Display-math hideTo: extends through directly following collapsed list
 *  close fences (whose own hides are suppressed), unless a collapsed callout
 *  close fence follows the run (R-T2 note). */
function displayHideTo(cell, inst, sel) {
  const L = lines(cell);
  let endLine = lineOfPos(cell, inst.to - 1);
  let hideTo = inst.to;
  const listCloses = new Set(
    cell.instances.filter((i) => i.kind === 'list' && i.items.length > 0).map((i) => i.closeLine),
  );
  for (;;) {
    const target = endLine + 1;
    if (target > L.count || !listCloses.has(target)) break;
    if (selOnLine(cell, sel, target, L.to(target - 1))) break;
    hideTo = L.to(target);
    endLine = target;
  }
  if (hideTo !== inst.to) {
    const next = endLine + 1;
    const calloutCloseFollows = cell.instances.some(
      (i) => i.kind === 'callout' && i.closeLine === next,
    );
    if (calloutCloseFollows) return inst.to;
  }
  return hideTo;
}

/** The hidden ranges ONE instance contributes under `sel`. */
function instanceHidden(cell, inst, sel, flags) {
  const L = lines(cell);
  const out = [];
  const push = (from, to, block = false) => {
    if (to > from) out.push({ from, to, block });
  };
  switch (inst.kind) {
    case 'inline-math':
      if (!instanceRevealed(cell, inst, sel, flags)) push(inst.from, inst.to);
      break;
    case 'display-math':
      if (!instanceRevealed(cell, inst, sel, flags)) {
        push(blockFrom(cell, inst.from), displayHideTo(cell, inst, sel), true);
      }
      break;
    case 'display-unclosed':
    case 'none':
      break;
    case 'command':
      if (!instanceRevealed(cell, inst, sel, flags)) {
        push(inst.cmdFrom, inst.argFrom);
        push(inst.argTo, inst.argTo + 1);
      }
      break;
    case 'pill':
      if (!instanceRevealed(cell, inst, sel, flags)) push(inst.cmdFrom, inst.argTo + 1);
      break;
    case 'href':
      if (!instanceRevealed(cell, inst, sel, flags)) {
        push(inst.cmdFrom, inst.textFrom);
        push(inst.textTo, inst.textTo + 1);
      }
      break;
    case 'whole-replace':
      if (!instanceRevealed(cell, inst, sel, flags)) push(inst.from, inst.to);
      break;
    case 'marker-pair':
      if (!instanceRevealed(cell, inst, sel, flags)) {
        for (const h of inst.hides) push(h.from, h.to);
      }
      break;
    case 'heading-attr':
      if (!instanceRevealed(cell, inst, sel, flags)) push(inst.attrFrom, inst.nodeTo);
      break;
    case 'callout': {
      // Open fence: label widget replaces the line text (selection-on-line).
      if (!selOnLine(cell, sel, inst.openLine)) {
        push(L.from(inst.openLine), L.to(inst.openLine));
      }
      // Close fence: collapsed with its preceding newline.
      if (!selOnLine(cell, sel, inst.closeLine, L.to(inst.closeLine - 1))) {
        push(L.to(inst.closeLine - 1), L.to(inst.closeLine));
      }
      break;
    }
    case 'list': {
      if (inst.items.length === 0) break;
      if (
        !inst.openHasArgs &&
        !selOnLine(cell, sel, inst.openLine, L.to(inst.openLine - 1)) &&
        !listFenceConsumedByMath(cell, inst.openLine)
      ) {
        push(L.to(inst.openLine - 1), L.to(inst.openLine));
      }
      if (
        !selOnLine(cell, sel, inst.closeLine, L.to(inst.closeLine - 1)) &&
        !listFenceConsumedByMath(cell, inst.closeLine)
      ) {
        push(L.to(inst.closeLine - 1), L.to(inst.closeLine));
      }
      for (const it of inst.items) {
        if (!revealChar(sel, it.from, it.to)) push(it.from, it.to);
      }
      break;
    }
    case 'frame': {
      if (!selOnLine(cell, sel, inst.openLine)) {
        push(L.from(inst.openLine), L.to(inst.openLine));
      }
      // The \end{frame} text hides but its ROW survives (no newline absorbed).
      if (!selOnLine(cell, sel, inst.closeLine)) {
        push(L.from(inst.closeLine), L.to(inst.closeLine));
      }
      break;
    }
    case 'table': {
      const from = L.from(inst.fromLine);
      let to = L.to(inst.toLine);
      // hideTo absorption of a directly following collapsed callout close.
      const next = inst.toLine + 1;
      const callout = cell.instances.find((i) => i.kind === 'callout' && i.closeLine === next);
      if (callout && !selOnLine(cell, sel, next, L.to(next - 1))) to = L.to(next);
      push(from, to, true);
      break;
    }
    default:
      throw new Error(`rules: unknown kind ${inst.kind}`);
  }
  return out;
}

function mergeRanges(ranges) {
  const sorted = [...ranges].sort((a, b) => a.from - b.from || a.to - b.to);
  const merged = [];
  for (const r of sorted) {
    const last = merged[merged.length - 1];
    if (last && r.from <= last.to) {
      last.to = Math.max(last.to, r.to);
      last.block = last.block || r.block;
    } else {
      merged.push({ ...r });
    }
  }
  return merged;
}

/** O-2: the full predicted hidden set (merged extents + block flags). */
export function predictHidden(cell, sel, flags = {}) {
  const all = [];
  for (const inst of cell.instances) all.push(...instanceHidden(cell, inst, sel, flags));
  return mergeRanges(all);
}

/** O-1 whitelist: every extent a hide may legally fall inside. */
export function constructExtents(cell) {
  const L = lines(cell);
  const out = [];
  for (const inst of cell.instances) {
    switch (inst.kind) {
      case 'inline-math':
      case 'display-unclosed':
      case 'whole-replace':
        out.push([inst.from, inst.to]);
        break;
      case 'display-math':
        // The block replace legally starts at the line start over leading
        // whitespace (R-T2/R-M2 blockFrom), so the extent covers it.
        out.push([blockFrom(cell, inst.from), inst.to]);
        break;
      case 'command':
      case 'pill':
        out.push([inst.cmdFrom, inst.argTo + 1]);
        break;
      case 'href':
        out.push([inst.cmdFrom, inst.textTo + 1]);
        break;
      case 'marker-pair':
      case 'heading-attr':
        out.push([inst.nodeFrom, inst.nodeTo]);
        break;
      case 'callout':
        out.push([L.from(inst.openLine), L.to(inst.openLine)]);
        out.push([L.to(inst.closeLine - 1), L.to(inst.closeLine)]);
        break;
      case 'list':
        out.push([L.to(inst.openLine - 1), L.to(inst.openLine)]);
        out.push([L.to(inst.closeLine - 1), L.to(inst.closeLine)]);
        for (const it of inst.items) out.push([it.from, it.to]);
        break;
      case 'frame':
        out.push([L.from(inst.openLine), L.to(inst.openLine)]);
        out.push([L.from(inst.closeLine), L.to(inst.closeLine)]);
        break;
      case 'table':
        out.push([L.from(inst.fromLine), L.to(inst.toLine)]);
        break;
      case 'none':
        break;
      default:
        throw new Error(`rules: unknown kind ${inst.kind}`);
    }
  }
  return out;
}

export function isInsideHidden(cell, sel, pos, flags = {}) {
  return predictHidden(cell, sel, flags).some((h) => pos > h.from && pos < h.to);
}

/** O-4: predicted zero-width widget points (display previews) and atomic
 *  ranges (the table). */
export function predictWidgets(cell, sel, flags = {}) {
  const L = lines(cell);
  const out = [];
  for (const inst of cell.instances) {
    if (inst.kind === 'display-math' && instanceRevealed(cell, inst, sel, flags)) {
      // The preview sits after the collapsed close fence of a callout whose
      // last body element this block is (R-T2/R-M2: the fence hide keeps its
      // merge host, no phantom row — FINDINGS.md #1/#2); after `to` otherwise.
      let pos = inst.to;
      const startLine = lineOfPos(cell, inst.from);
      const endLine = lineOfPos(cell, inst.to - 1);
      const callout = cell.instances.find(
        (i) =>
          i.kind === 'callout' && i.openLine < startLine && i.closeLine === endLine + 1,
      );
      if (callout && !selOnLine(cell, sel, callout.closeLine, L.to(callout.closeLine - 1))) {
        pos = L.to(callout.closeLine);
      }
      out.push({ pos, side: 1, block: true });
    }
  }
  return out.sort((a, b) => a.pos - b.pos);
}

export function predictAtomic(cell, sel) {
  const L = lines(cell);
  const out = [];
  for (const inst of cell.instances) {
    if (inst.kind !== 'table') continue;
    const from = L.from(inst.fromLine);
    let to = L.to(inst.toLine);
    const next = inst.toLine + 1;
    const callout = cell.instances.find((i) => i.kind === 'callout' && i.closeLine === next);
    if (callout && !selOnLine(cell, sel, next, L.to(next - 1))) to = L.to(next);
    out.push({ from, to });
  }
  return out;
}

// ---------------------------------------------------------------------------
//  Horizontal (R-H1, R-H2)
// ---------------------------------------------------------------------------

/** Next head for one Left/Right press. The catalogue is ASCII-only, so one
 *  grapheme is one position (the multi-byte grapheme dimension of R-H1 is
 *  owned by Tests/fixtures/caret/19,20,27,28). The GFM table's atomic range
 *  is crossed whole (R-H2). */
export function predictHorizontal(cell, head, dir, sel = { anchor: head, head }) {
  let target = head + (dir > 0 ? 1 : -1);
  if (target < 0) return 0;
  if (target > cell.doc.length) return cell.doc.length;
  for (const a of predictAtomic(cell, sel)) {
    if (target > a.from && target < a.to) return dir > 0 ? a.to : a.from;
  }
  return target;
}

// ---------------------------------------------------------------------------
//  Vertical topology (R-V1..R-V7)
// ---------------------------------------------------------------------------

/** Where one Up/Down press from `head` goes, at document-line resolution.
 *
 *  `opts.sameLineRow`: the caller measured that another visual row of the
 *  SAME document line exists in the pressed direction (the geometric truth
 *  behind moreWrappedRows) — every stop defers to it (R-V6).
 *
 *  Returns one of
 *    { kind: 'row',   targetLine, ruleId }   landing measured by slot scan
 *    { kind: 'stop',  targetLine, ruleId }   column-preserving fence/display stop
 *    { kind: 'table', pos, ruleId }          exact landing beyond the table
 *    { kind: 'edge' }                        document edge, engine default
 */
export function verticalTopology(cell, head, dir, sel = { anchor: head, head }, opts = {}) {
  const L = lines(cell);
  const cur = lineOfPos(cell, head);
  if (opts.sameLineRow) return { kind: 'row', targetLine: cur, ruleId: 'R-V6' };
  const target = cur + dir;
  if (target < 1 || target > L.count) return { kind: 'edge' };

  // R-V7: a rendered table is crossed whole (highest-precedence keymap).
  // The crossing spans the table's PARSE node: a callout close fence directly
  // below the rows is swallowed into the node, so it travels with the table
  // (vertical motion cannot stop on an absorbed fence; horizontal motion
  // still reaches it).
  for (const inst of cell.instances) {
    if (inst.kind !== 'table') continue;
    const swallowed = cell.instances.some(
      (i) => i.kind === 'callout' && i.closeLine === inst.toLine + 1,
    );
    const nodeEnd = swallowed ? inst.toLine + 1 : inst.toLine;
    if (target >= inst.fromLine && target <= nodeEnd) {
      if (dir > 0) {
        const after = nodeEnd + 1;
        return {
          kind: 'table',
          pos: after <= L.count ? L.from(after) : cell.doc.length,
          ruleId: 'R-V7',
        };
      }
      const before = inst.fromLine - 1;
      return { kind: 'table', pos: before >= 1 ? L.to(before) : 0, ruleId: 'R-V7' };
    }
  }

  // R-V3: collapsed fence stops (callout close, then list open/close), in
  // keymap registration order. Callout OPEN fences are widget rows, not stops.
  for (const inst of cell.instances) {
    if (inst.kind === 'callout' && inst.closeLine === target) {
      return { kind: 'stop', targetLine: target, ruleId: 'R-V3' };
    }
  }
  for (const inst of cell.instances) {
    if (inst.kind !== 'list' || inst.items.length === 0) continue;
    if ((inst.openLine === target && !inst.openHasArgs) || inst.closeLine === target) {
      return { kind: 'stop', targetLine: target, ruleId: 'R-V3' };
    }
  }

  // R-V4: entering a concealed display block on its fence line.
  for (const inst of cell.instances) {
    if (inst.kind !== 'display-math') continue;
    const first = lineOfPos(cell, inst.from);
    const last = lineOfPos(cell, inst.to - 1);
    if (dir > 0 && first === target) return { kind: 'stop', targetLine: target, ruleId: 'R-V4' };
    if (dir < 0 && last === target) return { kind: 'stop', targetLine: target, ruleId: 'R-V4' };
  }

  return { kind: 'row', targetLine: target, ruleId: 'R-V1' };
}

/** Column-preserving stop landing (sameColumnOnLine): same column, clamped
 *  to the target line length. */
export function stopLanding(cell, head, targetLine) {
  const L = lines(cell);
  const col = head - L.from(lineOfPos(cell, head));
  return Math.min(L.from(targetLine) + col, L.to(targetLine));
}

/** R-V5 (tex only): snap a raw vertical landing out of concealed
 *  widget-rendered spans. `sel` is the PRE-press selection (the state the
 *  engine computed the move against). */
export function applySnap(cell, sel, pos, flags = {}) {
  if (cell.language !== 'tex') return pos;
  const L = lines(cell);
  let snapped = null;
  for (const inst of cell.instances) {
    if (inst.kind === 'inline-math' && !instanceRevealed(cell, inst, sel, flags)) {
      if (pos >= inst.from && pos < inst.to) {
        const left = inst.from - 1;
        snapped =
          left < L.from(lineOfPos(cell, inst.from))
            ? inst.to
            : pos - inst.from <= inst.to - pos
              ? left
              : inst.to;
      }
    }
  }
  // Style regions in document order; the LAST match wins (innermost prefix).
  const style = cell.instances
    .filter((i) => i.kind === 'command' || i.kind === 'pill' || i.kind === 'href')
    .sort((a, b) => a.cmdFrom - b.cmdFrom);
  for (const inst of style) {
    if (instanceRevealed(cell, inst, sel, flags)) continue;
    if (inst.kind === 'pill') {
      const end = inst.argTo + 1;
      if (pos >= inst.cmdFrom && pos < end) {
        const left = inst.cmdFrom - 1;
        snapped =
          left < L.from(lineOfPos(cell, inst.cmdFrom))
            ? end
            : pos - inst.cmdFrom <= end - pos
              ? left
              : end;
      }
    } else {
      const argFrom = inst.kind === 'href' ? inst.textFrom : inst.argFrom;
      if (pos >= inst.cmdFrom && pos < argFrom) snapped = argFrom;
    }
  }
  return snapped ?? pos;
}

// ---------------------------------------------------------------------------
//  Click targets (R-P2)
// ---------------------------------------------------------------------------

/** Widget click targets: selector, its document-order occurrence index for
 *  that selector (an adjacent pair renders two widgets), and the exact caret
 *  landing. */
export function clickTargets(cell) {
  const out = [];
  const counts = new Map();
  const ordered = [...cell.instances].sort(
    (a, b) => (a.from ?? a.cmdFrom ?? 0) - (b.from ?? b.cmdFrom ?? 0),
  );
  for (const inst of ordered) {
    if (!inst.clickTarget) continue;
    let land;
    if (inst.kind === 'inline-math') land = inst.from;
    else if (inst.kind === 'display-math') land = blockFrom(cell, inst.from);
    else if (inst.kind === 'pill') land = inst.argFrom;
    else continue;
    const sel = inst.clickTarget.selector;
    const nth = counts.get(sel) ?? 0;
    counts.set(sel, nth + 1);
    out.push({ selector: sel, nth, land, rule: 'R-P2', construct: inst.construct });
  }
  return out;
}

// ---------------------------------------------------------------------------
//  Failure attribution
// ---------------------------------------------------------------------------

/** Best rule ID to cite for a hidden-set mismatch overlapping [from, to). */
export function ruleForRange(cell, from, to) {
  const L = lines(cell);
  for (const inst of cell.instances) {
    const extents = [];
    switch (inst.kind) {
      case 'inline-math':
      case 'display-math':
      case 'display-unclosed':
      case 'whole-replace':
        extents.push([inst.from, inst.to]);
        break;
      case 'command':
      case 'pill':
        extents.push([inst.cmdFrom, inst.argTo + 1]);
        break;
      case 'href':
        extents.push([inst.cmdFrom, inst.textTo + 1]);
        break;
      case 'marker-pair':
      case 'heading-attr':
        extents.push([inst.nodeFrom, inst.nodeTo]);
        break;
      case 'callout':
      case 'frame':
        extents.push([L.from(inst.openLine), L.to(inst.openLine)]);
        extents.push([L.to(inst.closeLine - 1), L.to(inst.closeLine)]);
        break;
      case 'list':
        extents.push([L.to(inst.openLine - 1), L.to(inst.openLine)]);
        extents.push([L.to(inst.closeLine - 1), L.to(inst.closeLine)]);
        for (const it of inst.items) extents.push([it.from, it.to]);
        break;
      case 'table':
        extents.push([L.from(inst.fromLine), L.to(inst.toLine) + 1]);
        break;
      default:
        break;
    }
    if (extents.some(([f, t]) => from < t && to > f)) return inst.rule;
  }
  return 'O-1';
}
