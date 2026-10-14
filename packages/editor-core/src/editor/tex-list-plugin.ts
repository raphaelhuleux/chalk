import { Decoration, DecorationSet, EditorView, WidgetType } from '@codemirror/view';
import {
  Extension,
  StateField,
  Text,
  EditorState,
  SelectionRange,
  type Range,
} from '@codemirror/state';
import { collapsedLineRange, collapsedLineRevealed, makeFenceStopKeymap } from './callout-core';
import { isPreviewMode } from './view-mode';
import { HIDE, revealReplacedSource, SYNTAX_DIM } from './reveal';
import { createRevealGate, revealSignal } from './reveal-gate';
import { mathRegionsOf, type MathRegion } from './tex-math-incremental';
import { regionAt } from './display-math-core';
import { texLines } from './tex-lines';
import { memoByDoc } from '../utils/memo-by-doc';
import { hangingIndentSkip, listHangEm } from './hanging-indent';
import '../styles/list-layout.css';

// ---------------------------------------------------------------------------
//  LaTeX enumerate/itemize rendered as lists: lone `\begin`/`\end` fence lines
//  collapse (the newline-absorbing idiom of callout-core's
//  closingFenceHideRange) and each line-leading `\item` becomes a marker widget
//  with its label. The rest of each item line is untouched, so inline math and
//  nested callouts keep rendering.
//
//  Preview lays lists out from structure, not source whitespace: every line in
//  a list body is indented by its nesting depth (in em, so any font aligns), its
//  leading whitespace is hidden, `\item` lines hang the marker in that indent,
//  and continuation lines start at the item's text column. hanging-indent.ts
//  stands down on those lines (`hangingIndentSkip`). Mixed keeps the source
//  layout: it may not hide anything.
//
//  Deliberate limits:
//  - list options are honored when they set `label=` (one `\arabic*`-style
//    counter), `start=`, the enumerate package's `[(i)]` shorthand, or only
//    spacing; anything else (`resume`, an unreadable label) keeps the fence
//    raw, dimmed, with default labels.
//  - `\item[custom]` keeps `[custom]` visible next to the marker.
//  - description envs are out of scope.
//  - an env with no `\item` stays fully revealed (nothing vanishes mid-typing).
//  - verbatim bodies are opaque: a list inside a code sample stays raw.
// ---------------------------------------------------------------------------

type TexListKind = 'enumerate' | 'itemize';

interface TexListItem {
  /** 1-based document line of the `\item`. */
  line: number;
  /** The `\item` token plus its trailing inline whitespace. */
  from: number;
  to: number;
  /** Rendered marker, e.g. `1.`, `(a)`, `•`. */
  label: string;
}

interface TexListRegion {
  kind: TexListKind;
  /** 1-based lines of the `\begin`/`\end` fences. */
  openLine: number;
  closeLine: number;
  /** 1-based nesting depth among same-kind envs (LaTeX counters nest per kind). */
  depth: number;
  /** `\begin{enumerate}[…]` with options we can't honor: the fence stays raw. */
  openStaysRaw: boolean;
  items: TexListItem[];
}

// Lone fence lines only: a fence sharing its line with other text stays raw.
const LIST_OPEN = /^\s*\\begin\{(enumerate|itemize)\}\s*(\[[^\]]*\])?\s*$/;
const LIST_CLOSE = /^\s*\\end\{(enumerate|itemize)\}\s*$/;
// Line-leading `\item` (not `\itemsep`) plus trailing inline whitespace.
const ITEM = /^(\s*)(\\item)(?![A-Za-z])[ \t]*/;

/** 1 → a, 26 → z, 27 → aa (bijective base-26; LaTeX errors past z, we don't). */
function alpha(n: number): string {
  let s = '';
  while (n > 0) {
    n--;
    s = String.fromCharCode(97 + (n % 26)) + s;
    n = Math.floor(n / 26);
  }
  return s;
}

function roman(n: number): string {
  const table: Array<[number, string]> = [
    [1000, 'm'],
    [900, 'cm'],
    [500, 'd'],
    [400, 'cd'],
    [100, 'c'],
    [90, 'xc'],
    [50, 'l'],
    [40, 'xl'],
    [10, 'x'],
    [9, 'ix'],
    [5, 'v'],
    [4, 'iv'],
    [1, 'i'],
  ];
  let s = '';
  for (const [v, r] of table) {
    while (n >= v) {
      s += r;
      n -= v;
    }
  }
  return s;
}

/** LaTeX default enumerate label sequence: 1. → (a) → i. → A. */
export function enumerateLabel(depth: number, n: number): string {
  switch (Math.min(depth, 4)) {
    case 1:
      return `${n}.`;
    case 2:
      return `(${alpha(n)})`;
    case 3:
      return `${roman(n)}.`;
    default:
      return `${alpha(n).toUpperCase()}.`;
  }
}

/** LaTeX default itemize symbols: • → – → ∗ → · */
export function itemizeLabel(depth: number): string {
  return ['•', '–', '∗', '·'][Math.min(depth, 4) - 1];
}

// ---------------------------------------------------------------------------
//  List options: enumitem keys and the enumerate package's shorthand
// ---------------------------------------------------------------------------

const COUNTERS: Record<string, (n: number) => string> = {
  arabic: String,
  alph: alpha,
  Alph: (n) => alpha(n).toUpperCase(),
  roman,
  Roman: (n) => roman(n).toUpperCase(),
};

/** enumerate-package tokens: `[(i)]`, `[a)]`, `[A.]`. */
const SHORTHAND: Record<string, (n: number) => string> = {
  '1': String,
  a: alpha,
  A: (n) => alpha(n).toUpperCase(),
  i: roman,
  I: (n) => roman(n).toUpperCase(),
};

/** Bullet spellings an itemize `label=` may use. */
const BULLETS: Record<string, string> = {
  '\\textbullet': '•',
  '\\bullet': '•',
  '\\textendash': '–',
  '--': '–',
  '---': '—',
  '\\textemdash': '—',
  '-': '−',
  '\\circ': '∘',
  '\\star': '⋆',
  '\\ast': '∗',
  '\\cdot': '·',
  '\\diamond': '⋄',
  '>': '>',
  '*': '∗',
};

/** Formatting that wraps a label without changing its text. */
const LABEL_FORMATTING = /\\(?:textbf|textit|textrm|textup|emph|upshape|itshape|bfseries|normalfont)\b|[{}$]/g;

/** Keys that change only spacing or layout, never the labels. */
const SPACING_KEY = /^(?:noitemsep|nosep|topsep|partopsep|parsep|itemsep|leftmargin|rightmargin|labelsep|labelwidth|labelindent|itemindent|align|widest|before|after|font|format|wide|listparindent)$/;

export interface ListOptions {
  /** Label for the n-th item (1-based), or null for LaTeX's default. */
  label: ((n: number) => string) | null;
  /** First item's number (`start=`). */
  start: number;
}

/** Split `a=1, b={x,y}` on top-level commas. */
function splitOptions(args: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let cur = '';
  for (const c of args) {
    if (c === '{') depth++;
    else if (c === '}') depth--;
    if (c === ',' && depth === 0) {
      parts.push(cur.trim());
      cur = '';
    } else cur += c;
  }
  if (cur.trim()) parts.push(cur.trim());
  return parts;
}

function enumerateTemplate(value: string): ((n: number) => string) | null {
  const text = value.replace(LABEL_FORMATTING, '');
  const counters = [...text.matchAll(/\\(arabic|alph|Alph|roman|Roman)\*/g)];
  if (counters.length !== 1) return null;
  const [token] = counters;
  const before = text.slice(0, token.index);
  const after = text.slice(token.index! + token[0].length);
  if (/\\/.test(before + after)) return null; // another command we can't render
  const counter = COUNTERS[token[1]];
  return (n) => `${before}${counter(n)}${after}`;
}

function itemizeTemplate(value: string): ((n: number) => string) | null {
  const text = value.replace(/[{}$]/g, '').trim();
  const bullet = BULLETS[text] ?? (/\\/.test(text) || text === '' ? null : text);
  return bullet == null ? null : () => bullet;
}

/**
 * The options in `\begin{enumerate}[…]` as far as they can be rendered, or
 * null when they change the labels in a way we can't reproduce (the fence then
 * stays raw and items keep default labels).
 */
export function parseListOptions(kind: TexListKind, args: string): ListOptions | null {
  const parts = splitOptions(args);
  // The enumerate package's shorthand: a lone template like `(i)` or `a)`.
  if (kind === 'enumerate' && parts.length === 1 && !parts[0].includes('=')) {
    const m = /^([^A-Za-z0-9\\]*)([1aAiI])([^A-Za-z0-9\\]*)$/.exec(parts[0]);
    if (m) {
      const counter = SHORTHAND[m[2]];
      return { label: (n) => `${m[1]}${counter(n)}${m[3]}`, start: 1 };
    }
  }
  const options: ListOptions = { label: null, start: 1 };
  for (const part of parts) {
    const eq = part.indexOf('=');
    const key = (eq === -1 ? part : part.slice(0, eq)).trim();
    const value = eq === -1 ? '' : part.slice(eq + 1).trim();
    if (key === 'label') {
      const label = kind === 'enumerate' ? enumerateTemplate(value) : itemizeTemplate(value);
      if (!label) return null;
      options.label = label;
    } else if (key === 'start' && kind === 'enumerate') {
      const n = Number.parseInt(value, 10);
      if (!Number.isFinite(n)) return null;
      options.start = n;
    } else if (!SPACING_KEY.test(key)) {
      return null; // `resume`, `series=…`, `ref=…`: numbering we can't follow
    }
  }
  return options;
}

/**
 * Scan for CLOSED enumerate/itemize regions, nesting-aware. Items belong to
 * the innermost open env, so siblings after an inner list continue the outer
 * count. A mismatched `\end` is body text; an env still open at EOF yields
 * nothing, so an in-progress block doesn't decorate.
 */
const DEFAULT_OPTIONS: ListOptions = { label: null, start: 1 };

export function scanTexListRegions(doc: Text): TexListRegion[] {
  const regions: TexListRegion[] = [];
  const stack: TexListRegion[] = [];
  const optionsOf = new Map<TexListRegion, ListOptions>();

  for (const { line, verbatim } of texLines(doc)) {
    if (verbatim) continue;
    const n = line.number;
    const text = line.text;

    const mOpen = LIST_OPEN.exec(text);
    if (mOpen) {
      const kind = mOpen[1] as TexListKind;
      const options = mOpen[2] == null ? DEFAULT_OPTIONS : parseListOptions(kind, mOpen[2].slice(1, -1));
      stack.push({
        kind,
        openLine: n,
        closeLine: 0,
        depth: 1 + stack.filter((e) => e.kind === kind).length,
        openStaysRaw: options == null,
        items: [],
      });
      optionsOf.set(stack[stack.length - 1], options ?? DEFAULT_OPTIONS);
      continue;
    }

    const mClose = LIST_CLOSE.exec(text);
    if (mClose && stack.length > 0 && stack[stack.length - 1].kind === mClose[1]) {
      const region = stack.pop()!;
      region.closeLine = n;
      regions.push(region);
      continue;
    }

    if (stack.length > 0) {
      const mItem = ITEM.exec(text);
      if (mItem) {
        const top = stack[stack.length - 1];
        const { label, start } = optionsOf.get(top)!;
        const ordinal = top.items.length + start;
        top.items.push({
          line: n,
          from: line.from + mItem[1].length,
          to: line.from + mItem[0].length,
          label: label
            ? label(ordinal)
            : top.kind === 'enumerate'
              ? enumerateLabel(top.depth, ordinal)
              : itemizeLabel(top.depth),
        });
      }
    }
  }

  return regions;
}

/** Cached per `Text`; treat the returned array as immutable. */
export const scanTexLists = memoByDoc(scanTexListRegions);

/**
 * Nesting depth (all list kinds) of every line strictly inside a rendered
 * list, keyed by 1-based line number. Nested fence lines count as the parent's
 * body. An env with no items renders nothing, so it adds no depth.
 */
export const texListLineDepths = memoByDoc((doc: Text): ReadonlyMap<number, number> => {
  const depths = new Map<number, number>();
  for (const r of scanTexLists(doc)) {
    if (r.items.length === 0) continue;
    for (let n = r.openLine + 1; n < r.closeLine; n++) depths.set(n, (depths.get(n) ?? 0) + 1);
  }
  return depths;
});

/** Lines of the fences that collapse to no visual row: the close fence, and
 *  the argless open fence, of every item-bearing list. */
export const collapsibleListFenceLines = memoByDoc((doc: Text): ReadonlySet<number> => {
  const lines = new Set<number>();
  for (const r of scanTexLists(doc)) {
    if (r.items.length === 0) continue;
    if (!r.openStaysRaw) lines.add(r.openLine);
    lines.add(r.closeLine);
  }
  return lines;
});

/**
 * End position extending a display-math block replace through the collapsed
 * close-fence line(s) directly below it, or null. The list analogue of
 * calloutBlockAt's `hideTo`: a fence merging into a line the math widget
 * consumed would leave a phantom empty row, so the math side absorbs it.
 * Walks consecutive fences (nested lists); a revealed fence stops the walk.
 */
export function listFenceHideThrough(
  doc: Text,
  from: number,
  to: number,
  main: SelectionRange,
): number | null {
  const regions = scanTexLists(doc);
  let endLine = doc.lineAt(Math.max(from, to - 1)).number;
  let result: number | null = null;
  while (endLine + 1 <= doc.lines) {
    const target = endLine + 1;
    if (!regions.some((r) => r.closeLine === target && r.items.length > 0)) break;
    if (collapsedLineRevealed(doc, main, target)) break;
    result = doc.line(target).to;
    endLine = target;
  }
  return result;
}

// ---------------------------------------------------------------------------
//  Marker widget
// ---------------------------------------------------------------------------

class ItemMarkerWidget extends WidgetType {
  constructor(private readonly label: string) {
    super();
  }

  eq(other: ItemMarkerWidget): boolean {
    return other.label === this.label;
  }

  toDOM(): HTMLElement {
    // Fills the line's hang (`--chalk-hang`, list-layout.css), so the item text
    // starts where its wrapped rows and continuation lines do.
    const span = document.createElement('span');
    span.className = 'cm-tex-item-marker';
    span.textContent = this.label;
    return span;
  }

  ignoreEvent(): boolean {
    return false; // let clicks through so the caret can land in the line
  }
}

// ---------------------------------------------------------------------------
//  Decorations
// ---------------------------------------------------------------------------

interface TexListOptions {
  /** `false` (Mixed): fences are dimmed and `\item` stays as source in the
   *  marker color, no widgets. Default true. */
  conceal?: boolean;
}

const ITEM_SOURCE = Decoration.mark({ class: 'cm-tex-item-source' });
const ITEM_TOKEN_LENGTH = '\\item'.length;
/** Preview, caret on the token: `\item ` shown raw but still filling the hang,
 *  so the text after it doesn't jump when the marker opens. */
const ITEM_REVEALED = Decoration.mark({ class: 'cm-tex-item-revealed' });
function listLine(depth: number, item: boolean): Decoration {
  return Decoration.line({
    class: item ? 'cm-tex-list-line cm-tex-list-item' : 'cm-tex-list-line cm-tex-list-cont',
    attributes: { style: `--chalk-hang:${listHangEm(depth)}em` },
  });
}

/** True when a selection-only update leaves every reveal decision (each
 *  list's fences and `\item` tokens) unchanged, so a rebuild is a no-op. */
function listSelectionIndependent(a: EditorState, b: EditorState): boolean {
  const { doc } = b;
  const was = a.selection.main;
  const now = b.selection.main;
  for (const n of collapsibleListFenceLines(doc)) {
    if (collapsedLineRevealed(doc, was, n) !== collapsedLineRevealed(doc, now, n)) return false;
  }
  for (const r of scanTexLists(doc)) {
    for (const item of r.items) {
      if (revealReplacedSource(was, item.from, item.to) !== revealReplacedSource(now, item.from, item.to)) {
        return false;
      }
    }
  }
  return true;
}

function buildTexListDecorations(state: EditorState, opts: TexListOptions = {}): DecorationSet {
  const conceal = opts.conceal ?? true;
  const { doc } = state;
  const cursor = state.selection.main;
  const regions = scanTexLists(doc);
  if (regions.length === 0) return Decoration.none;

  // A fence whose merge host is inside display math is absorbed by the math
  // widget (listFenceHideThrough), so this side emits no hide for it. The walk
  // skips intermediate close fences, which may themselves be math-absorbed.
  const mathRegions = mathRegionsOf(state);
  const closeFenceLines = new Set(
    regions.filter((r) => r.items.length > 0).map((r) => r.closeLine),
  );
  const mergeHostConsumedByMath = (lineNo: number): boolean => {
    let n = lineNo - 1;
    while (n >= 1 && closeFenceLines.has(n)) n--;
    if (n < 1) return false;
    return regionAt(mathRegions, doc.line(n).from) !== null;
  };

  const ranges: Range<Decoration>[] = [];
  // Fence lines with no row of their own (collapsed here, or absorbed by a
  // math widget): they get no layout.
  const hiddenFences = new Set<number>();
  // A fence whose merge host a math widget consumed is absorbed by that widget.
  const hideFence = (lineNo: number): void => {
    if (mergeHostConsumedByMath(lineNo)) return;
    const h = collapsedLineRange(doc, lineNo);
    ranges.push(HIDE.range(h.from, h.to));
  };

  for (const region of regions) {
    if (region.items.length === 0) continue; // empty env stays fully revealed

    const open = doc.line(region.openLine);
    const close = doc.line(region.closeLine);

    if (conceal) {
      if (region.openStaysRaw) {
        if (open.from < open.to) ranges.push(SYNTAX_DIM.range(open.from, open.to));
      } else if (!collapsedLineRevealed(doc, cursor, region.openLine)) {
        hiddenFences.add(region.openLine);
        hideFence(region.openLine);
      }

      if (!collapsedLineRevealed(doc, cursor, region.closeLine)) {
        hiddenFences.add(region.closeLine);
        hideFence(region.closeLine);
      }
    } else {
      if (open.from < open.to) ranges.push(SYNTAX_DIM.range(open.from, open.to));
      if (close.from < close.to) ranges.push(SYNTAX_DIM.range(close.from, close.to));
    }

    for (const item of region.items) {
      if (!conceal) {
        ranges.push(ITEM_SOURCE.range(item.from, item.from + ITEM_TOKEN_LENGTH));
        continue;
      }
      if (revealReplacedSource(cursor, item.from, item.to)) {
        ranges.push(ITEM_REVEALED.range(item.from, item.to));
        continue;
      }
      ranges.push(
        Decoration.replace({ widget: new ItemMarkerWidget(item.label) }).range(item.from, item.to),
      );
    }
  }

  if (conceal) addListLayout(state, mathRegions, hiddenFences, ranges);
  return Decoration.set(ranges, true);
}

/**
 * Preview's structural layout: each visible list body line gets its depth's
 * hang and loses its source indentation. Not a reveal: the hidden whitespace
 * never opens (a caret before it draws where the text starts), so the set
 * stays selection-independent apart from the fences above.
 */
function addListLayout(
  state: EditorState,
  mathRegions: readonly MathRegion[],
  hiddenFences: ReadonlySet<number>,
  ranges: Range<Decoration>[],
): void {
  const { doc } = state;
  const itemLines = new Map<number, TexListItem>();
  for (const r of scanTexLists(doc)) for (const item of r.items) itemLines.set(item.line, item);

  for (const [n, depth] of texListLineDepths(doc)) {
    if (hiddenFences.has(n)) continue;
    const line = doc.line(n);
    const item = itemLines.get(n);
    ranges.push(listLine(depth, item !== undefined).range(line.from));
    const textFrom = item ? item.from : line.from + /^[ \t]*/.exec(line.text)![0].length;
    // A display block replaces its lines from the line start; a second replace
    // over the same indent would overlap it.
    const math = regionAt(mathRegions, textFrom);
    if (textFrom > line.from && !(math && math.display)) ranges.push(HIDE.range(line.from, textFrom));
  }
}

/** List body lines in Preview, which lay themselves out: hanging-indent.ts
 *  leaves them alone. */
const listLinesSkipHang = hangingIndentSkip.of((state) => {
  const depths = texListLineDepths(state.doc);
  return (line) => depths.has(line);
});

// Line-break-replacing decorations must come from a StateField, not a ViewPlugin.
export function texListPlugin(opts: TexListOptions = {}): Extension {
  // The pointer freeze every reveal shares (reveal-gate.ts). Mixed reveals
  // nothing, so its set is selection-independent.
  const gate = createRevealGate({
    selectionIndependent: (opts.conceal ?? true) ? listSelectionIndependent : () => true,
  });
  const field = StateField.define<DecorationSet>({
    create(state) {
      return buildTexListDecorations(state, opts);
    },
    update(decos, tr) {
      if (gate.decide(revealSignal(tr)) !== 'rebuild') return decos.map(tr.changes);
      return buildTexListDecorations(tr.state, opts);
    },
    provide: (f) => EditorView.decorations.from(f),
  });
  return (opts.conceal ?? true) ? [field, listLinesSkipHang] : [field];
}

// ---------------------------------------------------------------------------
//  Fence stops: both list fences collapse to no visual row, so Up/Down needs a
//  stop on each (the makeFenceStopKeymap model). An args-bearing open fence
//  never collapses, so natural motion handles it.
// ---------------------------------------------------------------------------

export const texListFenceKeymap: Extension = makeFenceStopKeymap(
  memoByDoc((doc: Text) => [...collapsibleListFenceLines(doc)].map((closeLine) => ({ closeLine }))),
  isPreviewMode,
);

/**
 * A line the list plugin collapsed to no visual row, unless revealed. Handed
 * to callout-core by setup.ts, since callout-core must not import this module
 * (import cycle); it keeps `cm-callout-bottom` off rows CM6 would drop.
 */
export function texListLineCollapsed(state: EditorState, lineNo: number): boolean {
  return (
    collapsibleListFenceLines(state.doc).has(lineNo) &&
    !collapsedLineRevealed(state.doc, state.selection.main, lineNo)
  );
}
