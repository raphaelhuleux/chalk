import { Extension, Text } from '@codemirror/state';
import {
  LABELS,
  CalloutOpen,
  CalloutRegion,
  CalloutOptions,
  ScanCallouts,
  scanRegions,
  makeCalloutField,
  makeFenceStopKeymap,
} from './callout-core';
import { isPreviewMode } from './view-mode';
import { memoByDoc } from '../utils/memo-by-doc';

// Markdown surface syntax for callouts (Quarto fenced divs, `::: {.theorem}`).
// A line scanner only; everything else is shared via callout-core.

const FENCE_OPEN = /^\s*:::+\s*\{([^}]*)\}\s*$/;
const FENCE_CLOSE = /^\s*:::+\s*$/;
const NAME_ATTR = /\b(?:name|title)\s*=\s*(?:"([^"]*)"|'([^']*)')/;

// Quarto picks numbered, referenceable environments by ID prefix
// (`#thm-pythagoras`). Any other `#foo-bar` is a plain div.
export const NUMBERED_PREFIX: Record<string, string> = {
  thm: 'theorem',
  lem: 'lemma',
  cor: 'corollary',
  prp: 'proposition',
  cnj: 'conjecture',
  def: 'definition',
  exm: 'example',
  exr: 'exercise',
  // The figure div's LAST paragraph is its caption, so the completion snippet
  // puts notes above it.
  fig: 'figure',
};

// Referenceable by ID but unnumbered (`@prf-x` resolves to "Proof").
export const UNNUMBERED_PREFIX: Record<string, string> = {
  prf: 'proof',
  rem: 'remark',
  sol: 'solution',
};

// Group 1: full slug (for the cross-reference index); group 2: prefix.
const ID_ATTR = /#(([a-z]+)-[\w-]+)/;

// Unnumbered, non-referenceable classes. `callout-note` → type `note`.
const UNNUMBERED_CLASS = /\.(proof|remark|solution|callout-(?:note|tip|warning|important|caution))\b/;

export function isFenceClose(lineText: string): boolean {
  return FENCE_CLOSE.test(lineText);
}

/** Parse a fence-open line: an ID prefix (`{#thm-x name="…"}`, `{#prf-x}`) or a
 *  class (`{.proof}`, `{.callout-note}`). Null for anything else. */
export function parseFenceOpen(lineText: string): CalloutOpen | null {
  const fence = FENCE_OPEN.exec(lineText);
  if (!fence) return null;

  const attrs = fence[1];
  const nameMatch = NAME_ATTR.exec(attrs);
  const title = nameMatch ? (nameMatch[1] ?? nameMatch[2]) : null;

  // Classify with quoted values blanked, so `{.remark name="see #thm-x"}` is a
  // remark, not a theorem.
  const outsideQuotes = attrs.replace(/"[^"]*"|'[^']*'/g, '""');

  const id = ID_ATTR.exec(outsideQuotes);
  if (id) {
    const refId = id[1];
    const prefix = id[2];
    const numbered = NUMBERED_PREFIX[prefix];
    if (numbered)
      return { type: numbered, label: LABELS[numbered], title, refId, numbered: true, isClose: isFenceClose };
    const unnumbered = UNNUMBERED_PREFIX[prefix];
    if (unnumbered)
      return { type: unnumbered, label: LABELS[unnumbered], title, refId, numbered: false, isClose: isFenceClose };
  }

  const cls = UNNUMBERED_CLASS.exec(outsideQuotes);
  if (cls) {
    const raw = cls[1];
    const type = raw.startsWith('callout-') ? raw.slice('callout-'.length) : raw;
    return { type, label: LABELS[type], title, numbered: false, isClose: isFenceClose };
  }

  return null;
}

// Quarto's heading-title form, minus any trailing `{#id}`.
const CALLOUT_TITLE_HEADING = /^#{1,6}\s+(.+?)\s*(?:\{#[\w-]+\})?\s*$/;

/**
 * Title from a `## Heading` on the FIRST non-blank body line (Quarto's rule),
 * unless an attribute gave one. Mutates in place: safe, it runs before caching.
 */
function enrichHeadingTitles(regions: CalloutRegion[], doc: Text): CalloutRegion[] {
  for (const r of regions) {
    if (r.title) continue;
    for (let n = r.openLine + 1; n < r.closeLine; n++) {
      const text = doc.line(n).text;
      if (text.trim() === '') continue;
      const h = CALLOUT_TITLE_HEADING.exec(text);
      if (h) {
        r.title = h[1];
        r.titleLine = n;
      }
      break;
    }
  }
  return regions;
}

/** Cached Markdown callout scan, shared by the callout field, math and table
 *  widgets, the outline and the cross-reference index. Treat as immutable. */
export const scanCallouts: ScanCallouts = memoByDoc((doc: Text) =>
  enrichHeadingTitles(scanRegions(doc, parseFenceOpen, { skipCodeFences: true }), doc),
);

export function calloutPlugin(opts: CalloutOptions = {}): Extension {
  return makeCalloutField(scanCallouts, undefined, opts);
}

/** Up/Down stop on a collapsed `:::` and reveal it (see makeFenceStopKeymap). */
export const mdCalloutFenceKeymap: Extension = makeFenceStopKeymap(scanCallouts, isPreviewMode);
