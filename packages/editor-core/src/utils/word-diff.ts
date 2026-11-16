/**
 * Word-level hunks between two texts, for attributing an outside write. Sits
 * beside `diffReplace`, which stays the sync path for every other `update`:
 * that one collapses a multi-hunk write into a single replace, so it can't
 * tell which text changed.
 *
 * Diffs by line first, then by word inside each changed block, so a cost cap
 * degrades one block to a coarser hunk rather than the whole file.
 */
export interface Hunk {
  fromA: number;
  toA: number;
  fromB: number;
  toB: number;
}

type TokenSpan = [aStart: number, aEnd: number, bStart: number, bEnd: number];

const MAX_LINE_EDITS = 2000;
const MAX_WORD_EDITS = 1000;
/** Whole words, so `fixed` to `fast` marks the word and not `ixed` to `ast`. */
const WORD = /\s+|[\p{L}\p{N}_]+|[^]/gu;

/** Myers O(ND): matching runs excluded, or null past `maxEdits`. */
function tokenDiff(a: string[], b: string[], maxEdits: number): TokenSpan[] | null {
  const n = a.length;
  const m = b.length;
  const limit = Math.min(n + m, maxEdits);
  const offset = limit + 1;
  const v = new Int32Array(2 * limit + 3);
  const trace: Int32Array[] = [];
  let found = -1;
  search: for (let d = 0; d <= limit; d++) {
    // Step d only touches diagonals -d..d, so keep just that window.
    trace.push(v.slice(offset - d, offset + d + 1));
    for (let k = -d; k <= d; k += 2) {
      const down = k === -d || (k !== d && v[offset + k - 1] < v[offset + k + 1]);
      let x = down ? v[offset + k + 1] : v[offset + k - 1] + 1;
      let y = x - k;
      while (x < n && y < m && a[x] === b[y]) {
        x++;
        y++;
      }
      v[offset + k] = x;
      if (x >= n && y >= m) {
        found = d;
        break search;
      }
    }
  }
  if (found < 0) return null;

  // Walk back from the end. Each step is one token added or removed; spans
  // touching in both texts coalesce.
  const spans: TokenSpan[] = [];
  let x = n;
  let y = m;
  for (let d = found; d > 0; d--) {
    const prev = trace[d];
    const k = x - y;
    const at = (diag: number) => prev[diag + d];
    const down = k === -d || (k !== d && at(k - 1) < at(k + 1));
    const prevK = down ? k + 1 : k - 1;
    const aStart = at(prevK);
    const bStart = aStart - prevK;
    const aEnd = down ? aStart : aStart + 1;
    const bEnd = down ? bStart + 1 : bStart;
    const last = spans[spans.length - 1];
    if (last && last[0] === aEnd && last[2] === bEnd) {
      last[0] = aStart;
      last[2] = bStart;
    } else {
      spans.push([aStart, aEnd, bStart, bEnd]);
    }
    x = aStart;
    y = bStart;
  }
  return spans.reverse();
}

function tokenStarts(tokens: string[], base: number): number[] {
  const starts = new Array<number>(tokens.length + 1);
  let at = base;
  for (let i = 0; i < tokens.length; i++) {
    starts[i] = at;
    at += tokens[i].length;
  }
  starts[tokens.length] = at;
  return starts;
}

function linesOf(text: string): string[] {
  const lines = text.split('\n');
  const last = lines.length - 1;
  for (let i = 0; i < last; i++) lines[i] += '\n';
  if (lines[last] === '') lines.pop();
  return lines;
}

function wordHunksInBlock(a: string, b: string, baseA: number, baseB: number): Hunk[] {
  const whole = [{ fromA: baseA, toA: baseA + a.length, fromB: baseB, toB: baseB + b.length }];
  if (a === '' || b === '') return whole;
  const tokensA = a.match(WORD) ?? [];
  const tokensB = b.match(WORD) ?? [];
  const spans = tokenDiff(tokensA, tokensB, MAX_WORD_EDITS);
  if (!spans) return whole;
  const startsA = tokenStarts(tokensA, baseA);
  const startsB = tokenStarts(tokensB, baseB);
  return spans.map(([aStart, aEnd, bStart, bEnd]) => ({
    fromA: startsA[aStart],
    toA: startsA[aEnd],
    fromB: startsB[bStart],
    toB: startsB[bEnd],
  }));
}

const hunkSize = (h: Hunk): number => Math.max(h.toA - h.fromA, h.toB - h.fromB);

/** Join hunks a space or a small kept shard splits, so a rewritten sentence is
 *  one mark and Reject restores it whole. A shard no longer than the edit on
 *  either side is a coincidence of the words, not text the writer kept. Only
 *  on one original line, so a deleted paragraph stays apart from a word edit
 *  above it. Joined hunks grow, so repeat until stable. */
function joinNearby(hunks: Hunk[], a: string): Hunk[] {
  let current = hunks;
  for (;;) {
    const out: Hunk[] = [];
    for (const h of current) {
      const last = out[out.length - 1];
      const gap = last ? a.slice(last.toA, h.fromA) : '';
      const join =
        last &&
        ((gap.length <= 2 && /^[ \t]*$/.test(gap)) ||
          (gap.length <= Math.min(hunkSize(last), hunkSize(h)) &&
            !a.slice(last.fromA, h.toA).includes('\n')));
      if (join) {
        last.toA = h.toA;
        last.toB = h.toB;
      } else {
        out.push({ ...h });
      }
    }
    if (out.length === current.length) return out;
    current = out;
  }
}

/** Hunks in ascending order. Offsets are UTF-16 units into `a` and `b`. */
export function wordHunks(a: string, b: string): Hunk[] {
  if (a === b) return [];
  const linesA = linesOf(a);
  const linesB = linesOf(b);

  let head = 0;
  const headMax = Math.min(linesA.length, linesB.length);
  while (head < headMax && linesA[head] === linesB[head]) head++;
  let tail = 0;
  const tailMax = headMax - head;
  while (
    tail < tailMax &&
    linesA[linesA.length - 1 - tail] === linesB[linesB.length - 1 - tail]
  ) {
    tail++;
  }

  const midA = linesA.slice(head, linesA.length - tail);
  const midB = linesB.slice(head, linesB.length - tail);
  const prefixLength = linesA.slice(0, head).reduce((sum, line) => sum + line.length, 0);
  const startsA = tokenStarts(midA, prefixLength);
  const startsB = tokenStarts(midB, prefixLength);
  const blocks: TokenSpan[] = tokenDiff(midA, midB, MAX_LINE_EDITS) ?? [
    [0, midA.length, 0, midB.length],
  ];

  const hunks: Hunk[] = [];
  for (const [aStart, aEnd, bStart, bEnd] of blocks) {
    const fromA = startsA[aStart];
    const toA = startsA[aEnd];
    const fromB = startsB[bStart];
    const toB = startsB[bEnd];
    hunks.push(...wordHunksInBlock(a.slice(fromA, toA), b.slice(fromB, toB), fromA, fromB));
  }
  return joinNearby(hunks, a);
}
