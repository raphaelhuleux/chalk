import { Text } from '@codemirror/state';
import { CODE_FENCE, LABELS } from './callout-core';
import { scanCallouts } from './md-callout-plugin';
import { frontmatterCloseLine } from './md-frontmatter';
import { memoByDoc } from '../utils/memo-by-doc';

// Quarto `@key` index: one scan per document numbers every referenceable
// thing. Equation numbers, `@ref` pills and `@` completion all read it, and
// callout numbers come from `scanCallouts`, so none of them can disagree.

/** A resolved reference target. `number` is null for unnumbered-but-
 *  referenceable environments (proof/remark/solution). */
interface RefEntry {
  /** `sec`, `eq` or a callout type. */
  kind: string;
  label: string;
  number: string | null;
}

type CrossrefIndex = Map<string, RefEntry>;

const KIND_LABEL: Record<string, string> = { sec: 'Section', eq: 'Equation' };

const labelFor = (kind: string): string => KIND_LABEL[kind] ?? LABELS[kind] ?? kind;

const HEADING = /^(#{1,6})\s+.*\{#(sec-[\w-]+)\}\s*$/;
const HEADING_ANY = /^(#{1,6})\s+/;
/** A labelled closing `$$` at a line end, whatever precedes it: `$$ {#eq-…}`
 *  alone, or the close of a `$$ E = mc^2 $$ {#eq-…}` single-line block. */
const EQ_LABEL = /\$\$\s*\{#(eq-[\w-]+)\}\s*$/;

function buildCrossrefIndex(doc: Text): CrossrefIndex {
  scanMisses++;
  const index: CrossrefIndex = new Map();
  // Past the frontmatter, so a YAML `# comment` is never read as a heading.
  const bodyStart = frontmatterCloseLine(doc) + 1;

  // Callouts first: their regions mark lines where a `## Title` is not a
  // document section.
  const regions = scanCallouts(doc);
  const inCallout = new Array<boolean>(doc.lines + 2).fill(false);
  for (const r of regions) {
    for (let n = r.openLine; n <= r.closeLine; n++) inCallout[n] = true;
    if (r.refId) {
      index.set(r.refId, {
        kind: r.type,
        label: labelFor(r.type),
        number: r.number != null ? String(r.number) : null,
      });
    }
  }

  // Quarto numbers every section, labelled or not.
  const counters: number[] = [];
  // One global equation counter, including equations inside callouts.
  let eqCount = 0;

  // Fenced code is opaque (as to the callout scanner): a labelled sample there
  // is documentation, and must neither be indexed nor consume a number.
  let inCodeFence = false;

  // iterLines with a running number: `doc.line(n)` is a tree lookup per line.
  // iterLines throws past the last line, which frontmatter can reach.
  const body = bodyStart <= doc.lines ? doc.iterLines(bodyStart) : [];
  let n = bodyStart - 1;
  for (const text of body) {
    n++;

    if (CODE_FENCE.test(text)) {
      inCodeFence = !inCodeFence;
      continue;
    }
    if (inCodeFence) continue;

    const eq = EQ_LABEL.exec(text);
    if (eq) {
      eqCount++;
      index.set(eq[1], { kind: 'eq', label: labelFor('eq'), number: String(eqCount) });
      continue;
    }

    if (inCallout[n]) continue;

    const anyHeading = HEADING_ANY.exec(text);
    if (anyHeading) {
      const level = anyHeading[1].length;
      counters.length = level;
      counters[level - 1] = (counters[level - 1] ?? 0) + 1;
      // `Array.from`, not `.map`: a skipped level leaves holes, which `map`
      // doesn't visit, giving `1..1` instead of `1.0.1`.
      const number = Array.from(counters.slice(0, level), (c) => c ?? 0).join('.');
      const labelled = HEADING.exec(text);
      if (labelled) {
        index.set(labelled[2], { kind: 'sec', label: labelFor('sec'), number });
      }
    }
  }

  return index;
}

// Test-only: cache-miss builds, so a perf test can lock the caching.
let scanMisses = 0;
export function __crossrefScanCount(): number {
  return scanMisses;
}
export function __resetCrossrefScanCount(): void {
  scanMisses = 0;
}

/** The cross-reference index for `doc`, cached per immutable `Text`. */
export const crossrefIndex = memoByDoc(buildCrossrefIndex);
