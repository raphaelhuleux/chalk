import { ChangeSet, EditorState, StateField, Text } from '@codemirror/state';
import { regionAt, type DisplayMathRegion } from './display-math-core';
import { docText } from '../utils/doc-text';

/**
 * A tex math region, already a `DisplayMathRegion` so the cached scan is handed
 * over without a copy (`block` defaults to `display`).
 */
export interface MathRegion extends DisplayMathRegion {
  /** Document offset of the opening delimiter. */
  from: number;
  /** Document offset one past the closing delimiter. */
  to: number;
  /** True = `$$…$$`, `\[…\]`, or `\begin{…}…\end{…}`; false = `$…$`, `\(…\)`. */
  display: boolean;
  /** Source for KaTeX; environments keep their `\begin…\end` wrapper. */
  content: string;
}

const MATH_ENVIRONMENTS = new Set([
  'equation',
  'equation*',
  'align',
  'align*',
  'gather',
  'gather*',
  'multline',
  'multline*',
  'alignat',
  'alignat*',
  'eqnarray',
  'eqnarray*',
]);

/**
 * Optional scan report: `dangling` is true when an opener has no closer within
 * `text`. A window with none ends at top level, exactly where a full scan
 * would be, which is what makes the incremental reconvergence sound.
 */
export interface ScanOutcome {
  dangling: boolean;
}

/** Test instrumentation: `scanMathRegions` calls (test/typing-perf.test.ts). */
let scanInvocations = 0;
export function __scanCount(): number {
  return scanInvocations;
}
export function __resetScanCount(): void {
  scanInvocations = 0;
}

/**
 * Non-overlapping math regions of `text` in document order, positions shifted
 * by `offset`. Recognises `$…$`, `$$…$$`, `\(…\)`, `\[…\]` and
 * `\begin{env}…\end{env}` for env in MATH_ENVIRONMENTS; skips `%` comments and
 * `\x` escapes (so `\$` is literal).
 *
 * Not handled: verbatim/lstlisting (a `$` inside is taken as math; KaTeX
 * fails and the raw text shows) and nested same-name environments.
 */
export function scanMathRegions(
  text: string,
  offset = 0,
  outcome?: ScanOutcome,
): MathRegion[] {
  scanInvocations++;
  const regions: MathRegion[] = [];
  const n = text.length;
  let i = 0;

  while (i < n) {
    const ch = text[i];

    // `\%` is consumed by the backslash branch, so a `%` here is a comment.
    if (ch === '%') {
      while (i < n && text[i] !== '\n') i++;
      continue;
    }

    if (ch === '\\') {
      if (text[i + 1] === '[') {
        const end = text.indexOf('\\]', i + 2);
        if (end === -1 && outcome) outcome.dangling = true;
        if (end !== -1) {
          regions.push({
            from: offset + i,
            to: offset + end + 2,
            display: true,
            content: text.slice(i + 2, end),
          });
          i = end + 2;
          continue;
        }
      }
      if (text[i + 1] === '(') {
        const end = text.indexOf('\\)', i + 2);
        if (end === -1 && outcome) outcome.dangling = true;
        if (end !== -1) {
          regions.push({
            from: offset + i,
            to: offset + end + 2,
            display: false,
            content: text.slice(i + 2, end),
          });
          i = end + 2;
          continue;
        }
      }
      const beginMatch = matchBegin(text, i);
      if (beginMatch && MATH_ENVIRONMENTS.has(beginMatch.env)) {
        const endMarker = `\\end{${beginMatch.env}}`;
        const endIdx = text.indexOf(endMarker, i + beginMatch.length);
        if (endIdx === -1 && outcome) outcome.dangling = true;
        if (endIdx !== -1) {
          const regionEnd = endIdx + endMarker.length;
          regions.push({
            from: offset + i,
            to: offset + regionEnd,
            display: true,
            content: text.slice(i, regionEnd),
          });
          i = regionEnd;
          continue;
        }
      }
      // Any other escape: skip both chars so `\$` is not a delimiter.
      i += 2;
      continue;
    }

    if (ch === '$' && text[i + 1] === '$') {
      const end = text.indexOf('$$', i + 2);
      if (end === -1 && outcome) outcome.dangling = true;
      if (end !== -1) {
        regions.push({
          from: offset + i,
          to: offset + end + 2,
          display: true,
          content: text.slice(i + 2, end),
        });
        i = end + 2;
        continue;
      }
      // No closing $$: skip both chars, or the inline branch pairs them into
      // an empty, invisible `$…$` widget.
      i += 2;
      continue;
    }

    if (ch === '$') {
      const end = findInlineDollarClose(text, i + 1);
      if (end === -1 && outcome) outcome.dangling = true;
      if (end !== -1) {
        regions.push({
          from: offset + i,
          to: offset + end + 1,
          display: false,
          content: text.slice(i + 1, end),
        });
        i = end + 1;
        continue;
      }
    }

    i++;
  }

  return regions;
}

/** `\begin{name}` or `\begin{name*}` at `i`: the name and the tag length. */
function matchBegin(
  text: string,
  i: number,
): { env: string; length: number } | null {
  if (text.slice(i, i + 7) !== '\\begin{') return null;
  const closeBrace = text.indexOf('}', i + 7);
  if (closeBrace === -1) return null;
  const env = text.slice(i + 7, closeBrace);
  if (!/^[A-Za-z]+\*?$/.test(env)) return null;
  return { env, length: closeBrace - i + 1 };
}

/** Next unescaped `$` from `start`, or -1. Stops at a blank line, as TeX does,
 *  so one stray `$` can't swallow the document up to the next `$`. */
function findInlineDollarClose(text: string, start: number): number {
  let j = start;
  while (j < text.length) {
    const c = text[j];
    if (c === '\\') {
      j += 2;
      continue;
    }
    if (c === '$') return j;
    if (c === '\n') {
      let k = j + 1;
      while (k < text.length && (text[k] === ' ' || text[k] === '\t')) k++;
      if (k >= text.length || text[k] === '\n') return -1; // paragraph break
    }
    j++;
  }
  return -1;
}

/**
 * Incremental `scanMathRegions`: a full scan per keystroke grows linearly with
 * the file and was a large share of tex typing cost.
 *
 * Sound because the scanner's whole state is "inside a region or a comment?",
 * regions never nest and comments end at a newline: at a line start no region
 * strictly contains, the state is known. Restarting there reproduces the full
 * scan, and once the rescan reaches such a line start past the edit, the
 * suffix is the old one shifted.
 *
 * Trap: an opener with no closer (a half-typed `$`) is in no region, yet new
 * text can give it a partner and form a region spanning a boundary. So reuse
 * is gated on the previous scan having no stray opener (`MathScan.hasStray`);
 * such a document takes the full scan until the delimiter is closed.
 */

/** A scan result plus the one bit of state the next incremental scan needs. */
export interface MathScan {
  regions: MathRegion[];
  /** An opener in this document has no closer. Blocks incremental reuse. */
  hasStray: boolean;
}

/** Test instrumentation: characters the rescan actually read. */
let rescanChars = 0;
export function __rescanCharCount(): number {
  return rescanChars;
}
export function __resetRescanCharCount(): void {
  rescanChars = 0;
}

/** Scan a whole document, recording whether it holds a stray opener. */
export function fullMathScan(doc: Text): MathScan {
  const text = docText(doc);
  const outcome: ScanOutcome = { dangling: false };
  rescanChars += text.length;
  return { regions: scanMathRegions(text, 0, outcome), hasStray: outcome.dangling };
}

/** The region strictly containing `pos` (`from < pos < to`): never a valid
 *  rescan boundary. */
export function mathStrictlyContaining(
  regions: readonly MathRegion[],
  pos: number,
): MathRegion | undefined {
  const r = regionAt(regions, pos);
  return r && r.from < pos ? r : undefined;
}

/** The changed span of `changes`: lowest old start, highest old end, highest
 *  new end. Null for an empty change set. */
export function changeExtent(
  changes: ChangeSet,
): { minA: number; maxA: number; maxB: number } | null {
  let minA = Infinity;
  let maxA = -1;
  let maxB = -1;
  changes.iterChangedRanges((fromA, toA, _fromB, toB) => {
    if (fromA < minA) minA = fromA;
    if (toA > maxA) maxA = toA;
    if (toB > maxB) maxB = toB;
  });
  return maxA < 0 ? null : { minA, maxA, maxB };
}

/** The greatest line start at or before `pos` that no region strictly
 *  contains. A covering region's own start is top level, so walk back to it. */
function boundaryAtOrBefore(
  doc: Text,
  regions: readonly MathRegion[],
  pos: number,
): number {
  let p = doc.lineAt(Math.max(0, Math.min(pos, doc.length))).from;
  for (;;) {
    const covering = mathStrictlyContaining(regions, p);
    if (!covering) return p;
    const next = doc.lineAt(covering.from).from;
    if (next >= p) return 0; // defensive: never loop
    p = next;
  }
}

/**
 * Where the rescan may stop: a line start in BOTH documents that no old region
 * straddles, in both coordinate systems. It must be STRICTLY past the last
 * change: a `%` inserted at a line start leaves the old position a line start
 * but puts the new one inside a comment. Past the change, the preceding
 * newline is in the shared suffix, so neither scanner is in a comment.
 */
function forwardBoundary(
  oldDoc: Text,
  newDoc: Text,
  oldRegions: readonly MathRegion[],
  maxB: number,
  shift: number,
): { oldPos: number; newPos: number } {
  const ends = { oldPos: oldDoc.length, newPos: newDoc.length };
  let nq = maxB >= newDoc.length ? newDoc.length : newDoc.lineAt(maxB).to + 1;
  for (;;) {
    if (nq >= newDoc.length) return ends;
    const oq = nq - shift;
    if (oq < 0 || oq > oldDoc.length) return ends;
    const covering = mathStrictlyContaining(oldRegions, oq);
    if (!covering) return { oldPos: oq, newPos: nq };
    const resumeNew = covering.to + shift;
    if (resumeNew >= newDoc.length) return ends;
    const next = newDoc.lineAt(resumeNew).to + 1;
    if (next <= nq) return ends; // defensive: never loop
    nq = next;
  }
}

/**
 * The math scan of `newDoc`, reusing what `changes` cannot have affected.
 * Equivalent to `fullMathScan(newDoc)`: pinned by test/scan-math-incremental.test.ts.
 */
export function rescanMathRegions(
  oldDoc: Text,
  newDoc: Text,
  changes: ChangeSet,
  prev: MathScan,
): MathScan {
  const extent = changeExtent(changes);
  if (!extent) return prev;
  const { minA, maxA, maxB } = extent;
  // A half-typed delimiter anywhere makes every boundary unsound (see above).
  if (prev.hasStray) return fullMathScan(newDoc);

  const oldRegions = prev.regions;
  const restartOld = boundaryAtOrBefore(oldDoc, oldRegions, minA);
  const restartNew = changes.mapPos(restartOld, -1);

  const head: MathRegion[] = [];
  for (const r of oldRegions) {
    if (r.to <= restartOld) head.push(r);
    else break; // regions are sorted and non-overlapping
  }

  // The suffix past the last change is identical, so one shift maps all of it.
  const shift = maxB - maxA;
  const { oldPos: tailOld, newPos: tailNew } = forwardBoundary(
    oldDoc,
    newDoc,
    oldRegions,
    maxB,
    shift,
  );

  const outcome: ScanOutcome = { dangling: false };
  const windowText = newDoc.sliceString(restartNew, tailNew);
  rescanChars += windowText.length;
  const middle = scanMathRegions(windowText, restartNew, outcome);

  if (outcome.dangling) {
    // The window is not self-contained, so reconvergence would be a guess.
    const rest = newDoc.sliceString(restartNew, newDoc.length);
    rescanChars += rest.length;
    const restOutcome: ScanOutcome = { dangling: false };
    return {
      regions: head.concat(scanMathRegions(rest, restartNew, restOutcome)),
      hasStray: restOutcome.dangling,
    };
  }

  const tail: MathRegion[] = [];
  for (const r of oldRegions) {
    if (r.from >= tailOld) {
      tail.push({ ...r, from: r.from + shift, to: r.to + shift });
    }
  }
  return { regions: head.concat(middle, tail), hasStray: false };
}

/**
 * The document's math regions, rescanned (incrementally) only on doc changes.
 * Read by the math render field and `isInMathContextTex`; must be registered
 * before its readers in setup.ts so it is current when they read it.
 */
export const mathRegionsField = StateField.define<MathScan>({
  create(state) {
    return fullMathScan(state.doc);
  },
  update(scan, tr) {
    return tr.docChanged
      ? rescanMathRegions(tr.startState.doc, tr.newDoc, tr.changes, scan)
      : scan;
  },
});

/** The cached math regions, or a direct scan when the field isn't installed. */
export function mathRegionsOf(state: EditorState): MathRegion[] {
  return state.field(mathRegionsField, false)?.regions ?? scanMathRegions(docText(state.doc));
}
