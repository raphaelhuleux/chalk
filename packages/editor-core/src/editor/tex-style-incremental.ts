import { ChangeSet, Text } from '@codemirror/state';
import { changeExtent, mathStrictlyContaining, type MathRegion } from './tex-math-incremental';
import { docText } from '../utils/doc-text';
import { findClosingBrace } from './tex-lines';

/**
 * A recognised LaTeX command occurrence. `from..to` spans the argument text
 * inside the braces (for `\href`, the second, display-text argument);
 * `cmdFrom` is the backslash, so `cmdFrom..to+1` is the whole command.
 */
export interface TexStyleRegion {
  cmdFrom: number;
  from: number;
  to: number;
  kind:
    | 'h1'
    | 'h2'
    | 'h3'
    | 'strong'
    | 'em'
    | 'tt'
    | 'underline'
    | 'sc'
    | 'runin'
    | 'frametitle'
    | 'framesubtitle'
    | 'ref'
    | 'cite'
    | 'label'
    | 'footnote'
    | 'caption'
    | 'href'
    | 'url';
  name: string;
  starred: boolean;
  /** Link target for `href`/`url` regions. */
  url?: string;
}

type Kind = TexStyleRegion['kind'];

/** Command name → style. Sectioning maps to the visual heading scale, which is
 *  deliberately separate from the ToC depth map in outline.ts (where
 *  part/chapter sit above section). */
const COMMAND_KINDS: Record<string, Kind> = {
  part: 'h1',
  chapter: 'h1',
  section: 'h1',
  subsection: 'h2',
  subsubsection: 'h3',
  paragraph: 'runin',
  subparagraph: 'runin',
  // beamer. Not h1/h2/h3: those carry the section counter, and a frame
  // title's number is the slide number, drawn by the card.
  frametitle: 'frametitle',
  framesubtitle: 'framesubtitle',
  textbf: 'strong',
  emph: 'em',
  textit: 'em',
  texttt: 'tt',
  underline: 'underline',
  textsc: 'sc',
  ref: 'ref',
  eqref: 'ref',
  cref: 'ref',
  Cref: 'ref',
  autoref: 'ref',
  vref: 'ref',
  cite: 'cite',
  citep: 'cite',
  citet: 'cite',
  citealt: 'cite',
  citealp: 'cite',
  parencite: 'cite',
  textcite: 'cite',
  label: 'label',
  footnote: 'footnote',
  caption: 'caption',
  href: 'href',
  url: 'url',
};

/** Kinds whose commands may carry `[…]` optional arguments before the brace. */
const OPT_ARG_KINDS = new Set<Kind>([
  'h1',
  'h2',
  'h3',
  'runin',
  'cite',
  'footnote',
  'caption',
  'frametitle',
  'framesubtitle',
]);

/**
 * At a backslash, match a known styling command and return the offset just
 * past its opening `{`, or null. The `{` must be on the same line, so a bare
 * `\emph` in prose can't grab a brace a line later.
 */
function matchStyleCommand(
  text: string,
  at: number,
): { kind: Kind; name: string; starred: boolean; argStart: number } | null {
  let j = at + 1;
  const nameStart = j;
  while (j < text.length && /[A-Za-z]/.test(text[j])) j++;
  const name = text.slice(nameStart, j);
  const kind = COMMAND_KINDS[name];
  if (!kind) return null;
  let starred = false;
  if (text[j] === '*') {
    starred = true;
    j++;
  }
  while (text[j] === ' ' || text[j] === '\t') j++;
  if (OPT_ARG_KINDS.has(kind)) {
    // Skip `[…]` groups (natbib cites take up to two), same line only.
    while (text[j] === '[') {
      let k = j + 1;
      while (k < text.length && text[k] !== ']' && text[k] !== '\n') {
        if (text[k] === '\\') k++;
        k++;
      }
      if (text[k] !== ']') return null;
      j = k + 1;
      while (text[j] === ' ' || text[j] === '\t') j++;
    }
  }
  if (text[j] !== '{') return null;
  return { kind, name, starred, argStart: j + 1 };
}

/** Set by a bounded scan when a `\command{` inside `text` has no closing brace
 *  within it (or matched but recorded nothing, see the `\href` branch). */
export interface StyleScanOutcome {
  unclosed: boolean;
}

/**
 * Scan LaTeX source for styleable command arguments in one pass, skipping `%`
 * comments and math regions. Nested commands are emitted independently
 * (`\textbf{\emph{x}}` yields both regions). `offset` is the document position
 * `text` starts at; `mathRegions` are absolute, sorted and non-overlapping.
 */
export function scanTexStyleRegions(
  text: string,
  mathRegions: MathRegion[],
  offset = 0,
  outcome?: StyleScanOutcome,
): TexStyleRegion[] {
  const regions: TexStyleRegion[] = [];
  const n = text.length;
  let i = 0;
  let mi = 0; // pointer into mathRegions

  while (i < n) {
    while (mi < mathRegions.length && offset + i >= mathRegions[mi].to) mi++;
    if (mi < mathRegions.length && offset + i >= mathRegions[mi].from) {
      i = mathRegions[mi].to - offset;
      continue;
    }

    const ch = text[i];

    if (ch === '%') {
      while (i < n && text[i] !== '\n') i++;
      continue;
    }

    if (ch === '\\') {
      const m = matchStyleCommand(text, i);
      if (m) {
        const close = findClosingBrace(text, m.argStart);
        if (close === -1 && outcome) outcome.unclosed = true;
        if (close !== -1) {
          if (m.kind === 'href') {
            // First group is the target, second the display text.
            let j = close + 1;
            while (text[j] === ' ' || text[j] === '\t') j++;
            if (text[j] === '{') {
              const textStart = j + 1;
              const textClose = findClosingBrace(text, textStart);
              if (textClose !== -1) {
                regions.push({
                  cmdFrom: offset + i,
                  from: offset + textStart,
                  to: offset + textClose,
                  kind: 'href',
                  name: m.name,
                  starred: false,
                  url: text.slice(m.argStart, close),
                });
                i = textStart;
                continue;
              }
            }
            // Matched but recorded nothing: its brace group is invisible to the
            // rescan's boundary test, so an edit could grow it across a
            // boundary unseen. Flag it like an unclosed group (full scan).
            if (outcome) outcome.unclosed = true;
          } else {
            const region: TexStyleRegion = {
              cmdFrom: offset + i,
              from: offset + m.argStart,
              to: offset + close,
              kind: m.kind,
              name: m.name,
              starred: m.starred,
            };
            if (m.kind === 'url') region.url = text.slice(m.argStart, close);
            regions.push(region);
            // Continue inside the argument so nested commands are found.
            i = m.argStart;
            continue;
          }
        }
      }
      // Other escapes (\$, \%, \\): skip both chars.
      i += 2;
      continue;
    }

    i++;
  }

  return regions;
}

/**
 * Incremental `scanTexStyleRegions` (a full rescan per keystroke was the
 * biggest cost of tex typing).
 *
 * Why it is sound: the scanner keeps no open/close state (it continues inside
 * each argument), so its state at a position is only "in math?", "in a
 * comment?", "mid-escape?". A line start outside every math region answers all
 * three (the scanner always lands on line starts, never steps over one), so
 * restarting there reproduces the full scan. A region STRADDLES a boundary when
 * its command is before it and its `}` after; boundaries back up to that
 * region's line. A `\command{` in the window that never closes within it sets
 * `StyleScanOutcome.unclosed` and falls back to a full scan.
 *
 * Only the window's output is sorted: the reused head and tail are already in
 * order and cannot interleave with it (the full sort was itself a hot spot).
 */

/** A scan result plus the bit of state the next incremental scan needs. */
export interface StyleScan {
  regions: TexStyleRegion[];
  /** A `\command{` in this document never closes. Blocks incremental reuse. */
  hasUnclosed: boolean;
}

/** Instrumentation: characters the rescan actually looked at. */
let rescanChars = 0;
export function __styleRescanCharCount(): number {
  return rescanChars;
}
export function __resetStyleRescanCharCount(): void {
  rescanChars = 0;
}

/** Sort by (from, to): nested regions share an ascending `from` but the outer
 *  one ends later, and RangeSetBuilder requires sorted input. */
function sorted(regions: TexStyleRegion[]): TexStyleRegion[] {
  return regions.sort((a, b) => a.from - b.from || a.to - b.to);
}

/** Scan a whole document, recording whether a command is left unclosed. */
export function fullStyleScan(doc: Text, mathRegions: MathRegion[]): StyleScan {
  const text = docText(doc);
  const outcome: StyleScanOutcome = { unclosed: false };
  rescanChars += text.length;
  return {
    regions: sorted(scanTexStyleRegions(text, mathRegions, 0, outcome)),
    hasUnclosed: outcome.unclosed,
  };
}

/** The greatest boundary at or before `pos`: a line start that no region
 *  straddles and no math region contains. A region's `to` is the index OF its
 *  closing `}`, so one whose brace opens line `p` (`to === p`) straddles it. */
function boundaryAtOrBefore(
  doc: Text,
  regions: readonly TexStyleRegion[],
  mathRegions: readonly MathRegion[],
  pos: number,
): number {
  let p = doc.lineAt(Math.max(0, Math.min(pos, doc.length))).from;
  for (;;) {
    const straddling = regions.find((r) => r.cmdFrom < p && r.to >= p);
    const math = mathStrictlyContaining(mathRegions, p);
    const back = Math.min(
      straddling ? straddling.cmdFrom : Infinity,
      math ? math.from : Infinity,
    );
    if (!Number.isFinite(back)) return p;
    const next = doc.lineAt(back).from;
    if (next >= p) return 0; // defensive: never loop
    p = next;
  }
}

/**
 * Where the rescan may stop, in both coordinate systems: the first line start
 * strictly past the last change (so the newline before it lies in the shared
 * suffix and it is a line start on BOTH sides), advanced past anything it
 * would cut through.
 */
function forwardBoundary(
  oldDoc: Text,
  newDoc: Text,
  oldRegions: readonly TexStyleRegion[],
  oldMath: readonly MathRegion[],
  maxB: number,
  shift: number,
): { oldPos: number; newPos: number } {
  const ends = { oldPos: oldDoc.length, newPos: newDoc.length };
  let nq = maxB >= newDoc.length ? newDoc.length : newDoc.lineAt(maxB).to + 1;
  for (;;) {
    if (nq >= newDoc.length) return ends;
    const oq = nq - shift;
    if (oq < 0 || oq > oldDoc.length) return ends;
    const straddling = oldRegions.find((r) => r.cmdFrom < oq && r.to >= oq);
    const math = mathStrictlyContaining(oldMath, oq);
    const resume = Math.max(
      straddling ? straddling.to : -1,
      math ? math.to : -1,
    );
    if (resume < 0) return { oldPos: oq, newPos: nq };
    const resumeNew = resume + shift;
    if (resumeNew >= newDoc.length) return ends;
    const next = newDoc.lineAt(resumeNew).to + 1;
    if (next <= nq) return ends; // defensive: never loop
    nq = next;
  }
}

/**
 * The style scan of `newDoc`, reusing everything `changes` cannot have
 * affected. Equivalent to `fullStyleScan(newDoc, newMathRegions)` for every
 * input (pinned by test/scan-style-incremental.test.ts).
 *
 * Boundaries are chosen against the old math regions, the window is scanned
 * against the new ones, and any difference between them outside the window
 * forces a full scan: typing `\[` can swallow styled text far from the caret.
 */
export function rescanStyleRegions(
  oldDoc: Text,
  newDoc: Text,
  changes: ChangeSet,
  prev: StyleScan,
  oldMathRegions: readonly MathRegion[],
  newMathRegions: MathRegion[],
): StyleScan {
  const extent = changeExtent(changes);
  if (!extent) return prev;
  const { minA, maxA, maxB } = extent;
  // An unclosed `\command{` makes every boundary after it suspect: new text
  // can close it, and the region that forms spans the boundary.
  if (prev.hasUnclosed) return fullStyleScan(newDoc, newMathRegions);

  const oldRegions = prev.regions;
  const restartOld = boundaryAtOrBefore(oldDoc, oldRegions, oldMathRegions, minA);
  const restartNew = changes.mapPos(restartOld, -1);

  const shift = maxB - maxA;
  const { oldPos: tailOld, newPos: tailNew } = forwardBoundary(
    oldDoc,
    newDoc,
    oldRegions,
    oldMathRegions,
    maxB,
    shift,
  );

  // A math-coverage change reaches as far as the region it opened or closed.
  // Old positions map as one splice: identity before it, +shift after
  // (anything inside it is already in the window).
  let mathDiffFrom = Infinity;
  let mathDiffTo = -1;
  const note = (from: number, to: number): void => {
    if (from < mathDiffFrom) mathDiffFrom = from;
    if (to > mathDiffTo) mathDiffTo = to;
  };
  const mapOld = (p: number): number => (p <= minA ? p : p + shift);
  const pairs = Math.max(oldMathRegions.length, newMathRegions.length);
  for (let k = 0; k < pairs; k++) {
    const a = oldMathRegions[k];
    const b = newMathRegions[k];
    if (a && b && mapOld(a.from) === b.from && mapOld(a.to) === b.to) continue;
    if (a) note(mapOld(a.from), mapOld(a.to));
    if (b) note(b.from, b.to);
  }
  if (mathDiffTo >= 0 && (mathDiffFrom < restartNew || mathDiffTo > tailNew)) {
    return fullStyleScan(newDoc, newMathRegions);
  }

  const outcome: StyleScanOutcome = { unclosed: false };
  const windowText = newDoc.sliceString(restartNew, tailNew);
  rescanChars += windowText.length;
  const middle = scanTexStyleRegions(windowText, newMathRegions, restartNew, outcome);

  if (outcome.unclosed) {
    return fullStyleScan(newDoc, newMathRegions);
  }

  const head: TexStyleRegion[] = [];
  const tail: TexStyleRegion[] = [];
  for (const r of oldRegions) {
    if (r.to < restartOld) head.push(r);
    else if (r.cmdFrom >= tailOld) {
      tail.push({ ...r, cmdFrom: r.cmdFrom + shift, from: r.from + shift, to: r.to + shift });
    }
  }
  return { regions: head.concat(sorted(middle), tail), hasUnclosed: false };
}
