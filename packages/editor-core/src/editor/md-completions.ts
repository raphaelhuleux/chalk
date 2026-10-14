/**
 * Markdown autocompletion: callout fences, `@` cross-references, fence
 * languages, link paths. Deliberately NOT a LaTeX command list: outside math
 * is prose, inside math is hsnips' ground.
 *
 * Each branch reads a table that already drives rendering (`LABELS`, the
 * callout prefix maps, `crossrefIndex`, `fenceLanguageNames`), so the popup
 * never offers something the renderer ignores.
 */

import {
  autocompletion,
  CompletionContext,
  CompletionResult,
  Completion,
} from '@codemirror/autocomplete';
import { EditorState, Extension, Text } from '@codemirror/state';
import { EditorView } from '@codemirror/view';

import { CODE_FENCE, LABELS } from './callout-core';
import {
  NUMBERED_PREFIX,
  UNNUMBERED_PREFIX,
  isFenceClose,
  parseFenceOpen,
} from './md-callout-plugin';
import { crossrefIndex } from './crossref-index';
import { fenceLanguageNames } from './code-languages';
import { insertSnippetBody } from './hsnips-plugin';
import { listFiles, workspaceAccessFacet, type WorkspaceFileKind } from './workspace-files';
import { emptyArgumentCompletion, emptySlotAt } from './completion-trigger';

// ── Callout fences ──────────────────────────────────────────────────

/** type → the `{…}` attribute md-callout-plugin recognises it by. */
const CALLOUT_ATTR: Record<string, string> = (() => {
  const attr: Record<string, string> = {};
  // A placeholder slug, not an empty `$1`: `parseFenceOpen` needs a
  // non-empty one, so `{#thm-}` would render as nothing while typing.
  for (const [abbrev, type] of Object.entries(NUMBERED_PREFIX)) {
    attr[type] = '#' + abbrev + '-${1:label}';
  }
  for (const type of Object.values(UNNUMBERED_PREFIX)) attr[type] = `.${type}`;
  for (const type of Object.keys(LABELS)) {
    if (!(type in attr)) attr[type] = `.callout-${type}`;
  }
  return attr;
})();

/**
 * The snippet each callout type inserts. In a figure, Quarto makes the last
 * paragraph the caption (quarto.org/docs/authoring/figures.html), so notes
 * go ABOVE it, and the caption is a placeholder, not an empty stop, so an
 * untouched insert doesn't promote the notes to caption.
 */
function calloutBody(type: string): string {
  if (type === 'figure') {
    return (
      '::: {#fig-${1:label}}\n' +
      '![]($2)\n' +
      '\n' +
      'Notes: $3\n' +
      '\n' +
      '${4:Caption}\n' +
      ':::'
    );
  }
  return '::: {' + CALLOUT_ATTR[type] + '}\n$0\n:::';
}

/** With no typed prefix the order is alphabetical (`caution` first); boost
 *  the common types. A typed prefix still decides the ranking. */
const CALLOUT_BOOST: Record<string, number> = {
  figure: 3,
  theorem: 2,
  proof: 2,
  note: 1,
  definition: 1,
};

/** A `:::` inside an open callout is its close, not a place for a new one. */
function insideCallout(doc: Text, lineNumber: number): boolean {
  let open = false;
  for (let n = 1; n < lineNumber; n++) {
    const text = doc.line(n).text;
    if (parseFenceOpen(text)) open = true;
    else if (isFenceClose(text)) open = false;
  }
  return open;
}

function calloutCompletions(context: CompletionContext): CompletionResult | null {
  const line = context.state.doc.lineAt(context.pos);
  const before = line.text.slice(0, context.pos - line.from);
  // `from` sits at the typed word so CM6 filters on `thm`, not the line.
  const m = /^\s*:::+\s*\{?\s*[#.]?([\w-]*)$/.exec(before);
  if (!m) return null;
  if (insideCallout(context.state.doc, line.number)) return null;

  const word = m[1];
  return {
    from: context.pos - word.length,
    options: Object.keys(LABELS).map((type) => ({
      label: type,
      type: 'class',
      boost: CALLOUT_BOOST[type],
      // The attribute (`#thm-`), the part of Quarto's syntax nobody remembers.
      detail:
        type === 'figure'
          ? 'image · notes · caption'
          : CALLOUT_ATTR[type].replace('${1:label}', '…'),
      // Rewrite the whole line, or a typed `::: {#th` leaves a half attribute.
      apply: (view: EditorView) => {
        const target = view.state.doc.lineAt(view.state.selection.main.head);
        insertSnippetBody(view, target.from, target.to, calloutBody(type));
      },
    })),
    validFor: /^[\w-]*$/,
  };
}

// ── Cross-references ────────────────────────────────────────────────

function crossrefCompletions(context: CompletionContext): CompletionResult | null {
  // Needs a char after `@` (a bare `@` is usually a handle); the lookbehind
  // keeps `user@host` out.
  const match = context.matchBefore(/(?<![\w\\])@[\w-]+/);
  if (!match) return null;

  const index = crossrefIndex(context.state.doc);
  const options: Completion[] = [];
  for (const [key, entry] of index) {
    options.push({
      label: key,
      type: 'variable',
      detail: entry.number ? `${entry.label} ${entry.number}` : entry.label,
    });
  }
  return { from: match.from + 1, options, validFor: /^[\w-]*$/ };
}

// ── Fenced-code languages ───────────────────────────────────────────

/** An odd number of fence lines above means this fence closes a block. */
function insideCodeBlock(doc: Text, lineNumber: number): boolean {
  let fences = 0;
  for (let n = 1; n < lineNumber; n++) {
    if (CODE_FENCE.test(doc.line(n).text)) fences++;
  }
  return fences % 2 === 1;
}

function fenceCompletions(context: CompletionContext): CompletionResult | null {
  const line = context.state.doc.lineAt(context.pos);
  const before = line.text.slice(0, context.pos - line.from);
  const m = /^\s{0,3}(?:```+|~~~+)\s*\{?\s*\.?([\w+#-]*)$/.exec(before);
  if (!m) return null;
  if (insideCodeBlock(context.state.doc, line.number)) return null;

  const word = m[1];
  return {
    from: context.pos - word.length,
    options: fenceLanguageNames.map((name) => ({
      label: name,
      type: 'class',
      detail: 'highlighted',
    })),
    validFor: /^[\w+#-]*$/,
  };
}

// ── Link and image paths ────────────────────────────────────────────

const LINK_PATH = /(!?)\[[^\]]*\]\(([^)\s]*)$/;

function isEmptyLinkPath(state: EditorState, pos: number): boolean {
  return emptySlotAt(state, pos, /(!?)\[[^\]]*\]\($/, ')');
}

/** An image link offers images; a plain link, notes or images. */
function linkPathCompletions(
  context: CompletionContext,
): Promise<CompletionResult | null> | null {
  const line = context.state.doc.lineAt(context.pos);
  const before = line.text.slice(0, context.pos - line.from);
  const m = LINK_PATH.exec(before);
  if (!m) return null;

  const kinds: WorkspaceFileKind[] = m[1] === '!' ? ['image'] : ['image', 'document'];
  const from = context.pos - m[2].length;
  return listFiles(context.state.facet(workspaceAccessFacet), kinds).then((paths) => ({
    from,
    options: paths.map((path) => ({ label: path, type: 'file' })),
    validFor: /^[^)\s]*$/,
  }));
}

// ── Public source + extension ───────────────────────────────────────

export function mdCompletionSource(
  context: CompletionContext,
): CompletionResult | Promise<CompletionResult | null> | null {
  return (
    calloutCompletions(context) ??
    fenceCompletions(context) ??
    linkPathCompletions(context) ??
    crossrefCompletions(context)
  );
}

export function mdCompletionExtension(): Extension {
  return [
    autocompletion({
      override: [mdCompletionSource],
      activateOnTyping: true,
      defaultKeymap: true,
    }),
    emptyArgumentCompletion(isEmptyLinkPath),
  ];
}
