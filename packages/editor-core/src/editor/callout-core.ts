import {
  Decoration,
  DecorationSet,
  EditorView,
  WidgetType,
  keymap,
  type Command,
} from '@codemirror/view';
import {
  Extension,
  StateField,
  Text,
  EditorState,
  EditorSelection,
  SelectionRange,
  Prec,
  type Line,
} from '@codemirror/state';
import '../styles/callout.css';
import { HIDE, lineRevealed, SYNTAX_DIM } from './reveal';
import { createRevealGate, revealSignal } from './reveal-gate';
import { memoByDoc } from '../utils/memo-by-doc';

// Language-neutral callout core. Markdown (Quarto `::: {.theorem}`) and LaTeX
// (`\begin{theorem}`) only supply a `parseOpen` line classifier; numbering,
// the label widget and the fence decorations all live here, which is what
// keeps both syntaxes identical. Add new callout behaviour here, not in one
// syntax. Only line decorations plus an open-fence widget are emitted, never
// interior ranges, so math/markup inside a callout keeps rendering.

/** Recognised environment types → display label. Every key needs an accent/tint
 *  pair (`--callout-accent`/`--callout-bg`) in callout.css, or the box renders
 *  invisible (css-guardrails.test.ts pins this). */
export const LABELS: Record<string, string> = {
  theorem: 'Theorem',
  lemma: 'Lemma',
  corollary: 'Corollary',
  proposition: 'Proposition',
  conjecture: 'Conjecture',
  definition: 'Definition',
  assumption: 'Assumption',
  example: 'Example',
  exercise: 'Exercise',
  figure: 'Figure',
  table: 'Table',
  proof: 'Proof',
  remark: 'Remark',
  solution: 'Solution',
  // beamer's block family: EMPTY label on purpose, the user's title is the
  // whole heading (CalloutLabelWidget.toDOM).
  block: '',
  alertblock: '',
  exampleblock: '',
  // Quarto admonitions: unnumbered, not cross-referenceable.
  note: 'Note',
  tip: 'Tip',
  warning: 'Warning',
  important: 'Important',
  caution: 'Caution',
};

/** Types that carry no auto-number. */
export const UNNUMBERED = new Set([
  'proof',
  'remark',
  'solution',
  'note',
  'tip',
  'warning',
  'important',
  'caution',
  'block',
  'alertblock',
  'exampleblock',
]);

/** The recognised open fence for one region, produced by a language scanner. */
export interface CalloutOpen {
  /** The recognised type, e.g. `theorem`. */
  type: string;
  /** Display label, e.g. `Theorem`. */
  label: string;
  /** Optional title (Quarto `title="…"`, LaTeX `[…]`). */
  title: string | null;
  /** Slug from an ID-form open (`::: {#thm-pythagoras}`), used by the
   *  cross-reference index. Undefined for class-form opens. */
  refId?: string;
  numbered: boolean;
  /** Whether a later line closes THIS region; per-open so the core stays
   *  syntax-agnostic (LaTeX closes over its env name). */
  isClose(lineText: string): boolean;
}

export interface CalloutRegion extends CalloutOpen {
  /** Per-type ordinal (1-based); undefined for unnumbered types. */
  number?: number;
  /** 1-based line numbers of the open and close fences. */
  openLine: number;
  closeLine: number;
  /** 1-based line of a `## Heading` title (Quarto), set by md-callout-plugin's
   *  post-scan. The line collapses into the label widget. */
  titleLine?: number;
}

/** A pure line → open-fence classifier supplied by each language. */
type ParseOpen = (lineText: string) => CalloutOpen | null;

interface ScanRegionsOptions {
  /** Markdown only: fenced code is opaque, so a callout shown inside a code
   *  sample stays raw. Tex callouts inside verbatim are left unguarded. */
  skipCodeFences?: boolean;
}

/** A ``` or ~~~ code-fence line. Shared with crossref-index.ts, which must agree
 *  on what is opaque or a sample's `{#eq-…}` numbers differently. */
export const CODE_FENCE = /^\s{0,3}(```|~~~)/;

// Test-only: cache-miss scan count, so a test can pin the caching invariant.
let scanMisses = 0;
export function __calloutScanCount(): number {
  return scanMisses;
}
export function __resetCalloutScanCount(): void {
  scanMisses = 0;
}

/**
 * Closed callout regions with per-type numbers, in document order. Unclosed
 * opens are dropped so a block being typed doesn't tint the rest of the doc.
 * Non-nested: an open inside a region is body text.
 */
export function scanRegions(
  doc: Text,
  parseOpen: ParseOpen,
  options: ScanRegionsOptions = {},
): CalloutRegion[] {
  scanMisses++;
  const regions: CalloutRegion[] = [];
  const counters: Record<string, number> = {};

  let open: CalloutOpen | null = null;
  let openLine = 0;
  let inCodeFence = false;

  let n = 0;
  for (const text of doc.iterLines()) {
    n++;

    if (options.skipCodeFences) {
      if (CODE_FENCE.test(text)) {
        inCodeFence = !inCodeFence;
        continue;
      }
      if (inCodeFence) continue;
    }

    if (open) {
      if (open.isClose(text)) {
        const region: CalloutRegion = { ...open, openLine, closeLine: n };
        if (open.numbered) {
          counters[open.type] = (counters[open.type] ?? 0) + 1;
          region.number = counters[open.type];
        }
        regions.push(region);
        open = null;
      }
      continue;
    }

    const parsed = parseOpen(text);
    if (parsed) {
      open = parsed;
      openLine = n;
    }
  }

  return regions;
}

export type ScanCallouts = (doc: Text) => CalloutRegion[];

/** `pos` moved to `lineNum` at the same column (clamped): the landing rule for
 *  every vertical keymap stop. */
export function sameColumnOnLine(state: EditorState, pos: number, lineNum: number): number {
  const from = state.doc.lineAt(pos).from;
  const target = state.doc.line(lineNum);
  return Math.min(target.from + (pos - from), target.to);
}

/**
 * Start position for a `block: true` replace of a construct opening at `from`.
 * CM6 block decorations must cover WHOLE lines: an indented `$$` (list
 * continuation) replaced from its indent leaves the whitespace as its own
 * `.cm-line`, a stray blank row and a height-map mis-pairing (widget overlaps
 * text). Snaps back over leading whitespace only; real text before it keeps
 * the offset (CM6 renders that as an inline replace).
 */
export function blockReplaceFrom(doc: Text, from: number): number {
  const line = doc.lineAt(from);
  if (line.from === from) return from;
  return line.text.slice(0, from - line.from).trim() === '' ? line.from : from;
}

/**
 * Vertical-motion goal session. CM6's `goalColumn` does not survive a
 * dispatch, so each Up/Down would re-anchor at the current x and a short line
 * or collapsed fence would lose the column. The session holds the pixel x
 * (moveVertically's `left - contentRect.left` convention) from the first
 * press of a run until something else moves the caret.
 */
const verticalSessions = new WeakMap<
  EditorView,
  { sel: EditorSelection; head: number; goalX: number }
>();

/** Goal x for a vertical press: the live session's, or a fresh capture
 *  (char-width estimate when the caret has no geometry). Liveness is keyed on
 *  the SELECTION OBJECT, not the head: a click onto the same position makes a
 *  new instance and must drop the goal, while effect-only transactions keep
 *  the instance and the run. */
export function verticalGoalX(view: EditorView): number {
  const { selection } = view.state;
  const head = selection.main.head;
  const session = verticalSessions.get(view);
  if (session && session.sel === selection && session.head === head) return session.goalX;
  const coords = view.coordsAtPos(head, selection.main.assoc || 1);
  const goalX = coords
    ? coords.left - view.contentDOM.getBoundingClientRect().left
    : view.defaultCharacterWidth * (head - view.state.doc.lineAt(head).from);
  verticalSessions.set(view, { sel: selection, head, goalX });
  return goalX;
}

/** Keep the session alive after a vertical landing. Call after dispatch: it
 *  records the new selection object for the identity check. */
export function recordVerticalLanding(view: EditorView, head: number): void {
  const session = verticalSessions.get(view);
  if (!session) return;
  session.sel = view.state.selection;
  session.head = head;
}

/** True when a default vertical move stays on the SAME document line (caret on
 *  an inner row of a wrapped line). Every line-adjacency stop must defer then,
 *  or it skips the remaining wrapped rows. */
export function moreWrappedRows(view: EditorView, dir: -1 | 1): boolean {
  // Three keymaps ask this per keydown and each call measures geometry twice.
  // Memoized for the current event turn only (microtask clear), so geometry
  // changes without a transaction can't leak in.
  if (
    wrappedRowsMemo &&
    wrappedRowsMemo.view === view &&
    wrappedRowsMemo.state === view.state &&
    wrappedRowsMemo.dir === dir
  ) {
    return wrappedRowsMemo.result;
  }
  const result = computeMoreWrappedRows(view, dir);
  if (!wrappedRowsMemo) queueMicrotask(() => (wrappedRowsMemo = null));
  wrappedRowsMemo = { view, state: view.state, dir, result };
  return result;
}

let wrappedRowsMemo: {
  view: EditorView;
  state: EditorState;
  dir: -1 | 1;
  result: boolean;
} | null = null;

function computeMoreWrappedRows(view: EditorView, dir: -1 | 1): boolean {
  const sel = view.state.selection.main;
  // Unmeasurable caret (collapsed fence, layoutless test env): let the stop fire.
  if (!view.coordsAtPos(sel.head, sel.assoc || 1)) return false;
  const moved = view.moveVertically(sel, dir > 0);
  if (moved.head === sel.head) return false; // document edge
  return (
    view.state.doc.lineAt(moved.head).number === view.state.doc.lineAt(sel.head).number
  );
}

/** Dispatch for every vertical keymap stop, keeping the goal session alive. */
export function dispatchVerticalStop(view: EditorView, pos: number): void {
  verticalGoalX(view); // capture-or-keep before the caret moves
  view.dispatch({
    selection: EditorSelection.cursor(pos),
    scrollIntoView: true,
    userEvent: 'select',
  });
  recordVerticalLanding(view, pos);
}

/**
 * Up/Down aimed at the goal-session x. Must be registered AFTER the fence-stop
 * and display-math keymaps (same Prec.high, later = lower priority) so it only
 * runs when none of them claims the press. `probe` overrides moveVertically's
 * distance, `snap` moves the landing.
 */
export function makeVerticalArrowKeymap(opts: {
  sourceModeActive: (state: EditorState) => boolean;
  probe?: (view: EditorView, head: number, assoc: number, forward: boolean) => number | undefined;
  snap?: (state: EditorState, pos: number) => number | null;
}): Extension {
  const move = (forward: boolean): Command => (view) => {
    if (opts.sourceModeActive(view.state)) return false;
    const sel = view.state.selection.main;
    if (!sel.empty) return false;
    const goalX = verticalGoalX(view);
    const moved = view.moveVertically(
      EditorSelection.cursor(sel.head, sel.assoc, undefined, goalX),
      forward,
      opts.probe?.(view, sel.head, sel.assoc, forward),
    );
    if (moved.head === sel.head) return false; // document edge: let CM6 decide
    const head = opts.snap?.(view.state, moved.head) ?? moved.head;
    view.dispatch({
      selection: EditorSelection.cursor(head),
      scrollIntoView: true,
      userEvent: 'select',
    });
    recordVerticalLanding(view, head);
    return true;
  };
  return Prec.high(
    keymap.of([
      { key: 'ArrowDown', run: move(true) },
      { key: 'ArrowUp', run: move(false) },
    ]),
  );
}

/** What a scanner must report for its collapsed rows to be reachable by
 *  vertical motion (callout and frame scanners both fit). */
type FenceStops = (doc: Text) => ReadonlyArray<{ closeLine: number; titleLine?: number }>;

/**
 * Up/Down stop ON a collapsed closing fence or title line, which reveals it.
 * A collapsed line has no visual row, so CM6's row-wise motion would skip it.
 * Declines for anything else, and only fires for an empty selection (so the
 * target line is collapsed by definition).
 */
export function makeFenceStopKeymap(
  scan: FenceStops,
  /** False when fences are raw rows (Mixed, Source): no stop needed. */
  active: (state: EditorState) => boolean = () => true,
): Extension {
  const stopOnFence = (dir: -1 | 1): Command => (view) => {
    const { state } = view;
    if (!active(state)) return false;
    const sel = state.selection.main;
    if (!sel.empty) return false;
    if (moreWrappedRows(view, dir)) return false; // finish the wrapped line first
    const line = state.doc.lineAt(sel.head);
    const targetNum = line.number + dir;
    if (targetNum < 1 || targetNum > state.doc.lines) return false;
    const stops = scan(state.doc).some(
      (r) => r.closeLine === targetNum || r.titleLine === targetNum,
    );
    if (!stops) return false;
    dispatchVerticalStop(view, sameColumnOnLine(state, sel.head, targetNum));
    return true;
  };
  return Prec.high(
    keymap.of([
      { key: 'ArrowUp', run: stopOnFence(-1) },
      { key: 'ArrowDown', run: stopOnFence(1) },
    ]),
  );
}

/**
 * One scan per document, shared by the decorations field and every
 * per-block `calloutBlockAt` lookup. The returned array is shared: treat it
 * as immutable.
 */
export function makeCachedScanner(parseOpen: ParseOpen): ScanCallouts {
  return memoByDoc((doc: Text) => scanRegions(doc, parseOpen));
}

// ── Label widget ──

class CalloutLabelWidget extends WidgetType {
  constructor(
    private readonly label: string,
    private readonly numberText: string,
    private readonly title: string | null,
    /** Quarto id shown as a dimmed pill; always null for LaTeX. */
    private readonly refId: string | null = null,
  ) {
    super();
  }

  eq(other: CalloutLabelWidget): boolean {
    return (
      other.label === this.label &&
      other.numberText === this.numberText &&
      other.title === this.title &&
      other.refId === this.refId
    );
  }

  toDOM(): HTMLElement {
    const span = document.createElement('span');
    span.className = 'cm-callout-label';
    // No type label (beamer blocks): the title is the heading.
    if (!this.label) {
      span.textContent = this.title ?? '';
      return span;
    }
    span.textContent = this.numberText ? `${this.label} ${this.numberText}` : this.label;
    if (this.title) {
      const em = document.createElement('em');
      em.className = 'cm-callout-title';
      em.textContent = ` (${this.title})`;
      span.appendChild(em);
    }
    if (this.refId) {
      const pill = document.createElement('span');
      pill.className = 'cm-md-label-pill';
      pill.textContent = this.refId;
      span.appendChild(pill);
    }
    return span;
  }

  ignoreEvent(): boolean {
    return false; // let clicks through so the caret can enter the fence line
  }
}

// ── Decorations ──

/**
 * Range that collapses line `lineNo` to no visual row: the PRECEDING line
 * break plus the line's text (the FOLLOWING break for line 1), so no phantom
 * empty row is left.
 * Must stay an INLINE replace: block replaces toggling on every selection
 * change corrupt CM6's height map and scroll anchoring. When display math is
 * the last body row it consumes the merge host, so the math widget absorbs the
 * fence instead (`calloutBlockAt`'s `hideTo`).
 */
export function collapsedLineRange(doc: Text, lineNo: number): { from: number; to: number } {
  const line = doc.line(lineNo);
  if (lineNo > 1) return { from: doc.line(lineNo - 1).to, to: line.to };
  if (lineNo < doc.lines) return { from: line.from, to: doc.line(lineNo + 1).from };
  return { from: line.from, to: line.to };
}

/** Whether a line collapsed by `collapsedLineRange` reveals (`lineRevealed`). */
export function collapsedLineRevealed(doc: Text, main: SelectionRange, lineNo: number): boolean {
  const line = doc.line(lineNo);
  const hidden = collapsedLineRange(doc, lineNo);
  return lineRevealed(main, line.from, line.to, hidden.from, hidden.to);
}

/** The collapsed closing fence of a callout. */
export function closingFenceHideRange(
  doc: Text,
  region: CalloutRegion,
): { from: number; to: number } {
  return collapsedLineRange(doc, region.closeLine);
}

/** A block widget's place in a callout box (`calloutBlockAt`). */
export interface CalloutTag {
  type: string;
  bottom: boolean;
}

/** Classes that let a block widget continue its callout box. */
export function calloutTagClasses(tag: CalloutTag | null): string[] {
  if (!tag) return [];
  const cls = ['cm-callout', `cm-callout-${tag.type}`];
  if (tag.bottom) cls.push('cm-callout-bottom');
  return cls;
}

/** Widget `eq` for the callout part. */
export function sameCalloutTag(a: CalloutTag | null, b: CalloutTag | null): boolean {
  return a?.type === b?.type && a?.bottom === b?.bottom;
}

/**
 * The callout a block widget (display math, table) sits strictly inside, so
 * its plugin can style it to continue the box: a block widget is not a
 * `.cm-line`, so per-line callout classes can't reach it. `bottom` marks the
 * box's last visual row. Pass `main`: a caret on the close fence reveals it,
 * and then the fence, not the widget, carries the bottom.
 */
export function calloutBlockAt(
  doc: Text,
  scan: ScanCallouts,
  from: number,
  to: number,
  main?: SelectionRange,
): { type: string; bottom: boolean; hideTo?: number } | null {
  const startLine = doc.lineAt(from).number;
  const endLine = doc.lineAt(Math.max(from, to - 1)).number;
  for (const r of scan(doc)) {
    if (startLine > r.openLine && endLine < r.closeLine) {
      const closeRevealed = main ? collapsedLineRevealed(doc, main, r.closeLine) : false;
      const bottom = endLine === r.closeLine - 1 && !closeRevealed;
      return {
        type: r.type,
        bottom,
        // The widget's replace must absorb the collapsed fence: the inline
        // fence-hide's merge host is gone, which would leave a phantom row.
        hideTo: bottom ? doc.line(r.closeLine).to : undefined,
      };
    }
  }
  return null;
}

/**
 * Where a REVEALED display block's preview widget goes: after `to`, or after
 * the collapsed close fence when the block is the callout's last body row. A
 * preview at `to` would split the fence-hide's merge host and leave a phantom
 * row outside the box (Tests/matrix/FINDINGS.md #1/#2). Edit-mode twin of
 * `hideTo`.
 */
export function displayPreviewPos(
  doc: Text,
  scan: ScanCallouts,
  from: number,
  to: number,
  main: SelectionRange,
): number {
  return calloutBlockAt(doc, scan, from, to, main)?.hideTo ?? to;
}

/** Whether another plugin collapsed a line to no visual row (tex-list's
 *  `\end{itemize}`). Passed in from setup.ts, not imported, to avoid a cycle. */
export type LineCollapsed = (state: EditorState, lineNo: number) => boolean;

export interface CalloutOptions {
  /** `false` is Mixed: fences stay as dimmed rows inside the box, the label
   *  floats as a `data-callout` chip, the title is marked in place, nothing
   *  reveals. */
  conceal?: boolean;
}

const TITLE_MARK = Decoration.mark({ class: 'cm-callout-title' });
const LABEL_MARK = Decoration.mark({ class: 'cm-callout-label' });

/** Where the title sits on the open line, for Mixed. Searched from just past
 *  `name=`/`title=` or `\begin{env}[`/`{`, so a title that recurs in the id
 *  (`::: {#thm-abc name="abc"}`) matches the right place. Null if no anchor. */
function titleRangeOnLine(line: Line, region: CalloutRegion): { from: number; to: number } | null {
  if (!region.title) return null;
  const text = line.text;
  const attrMatch = /\b(?:name|title)\s*=\s*["']/.exec(text);
  let anchor = attrMatch ? attrMatch.index + attrMatch[0].length : -1;
  if (anchor < 0) {
    const beginIdx = text.indexOf('\\begin{');
    if (beginIdx >= 0) {
      const envClose = text.indexOf('}', beginIdx);
      if (envClose >= 0 && (text[envClose + 1] === '[' || text[envClose + 1] === '{')) {
        anchor = envClose + 2;
      }
    }
  }
  if (anchor < 0) return null;
  const idx = text.indexOf(region.title, anchor);
  if (idx < 0) return null;
  return { from: line.from + idx, to: line.from + idx + region.title.length };
}

export function buildCalloutDecorations(
  state: EditorState,
  scan: ScanCallouts,
  lineCollapsed: LineCollapsed = () => false,
  opts: CalloutOptions = {},
): DecorationSet {
  const conceal = opts.conceal ?? true;
  const { doc } = state;
  const cursor = state.selection.main;
  const regions = scan(doc);
  if (regions.length === 0) return Decoration.none;

  const decos: Array<{ from: number; to: number; deco: Decoration }> = [];

  for (const region of regions) {
    const openLine = doc.line(region.openLine);
    const closeLine = doc.line(region.closeLine);

    const typeClass = `cm-callout cm-callout-${region.type}`;

    const titleLineNo = region.titleLine;
    const hideTitle =
      conceal && titleLineNo != null && !collapsedLineRevealed(doc, cursor, titleLineNo);

    // A collapsed close fence has no row, so the bottom moves to the last body line.
    const hideClose = conceal && !collapsedLineRevealed(doc, cursor, region.closeLine);
    let bottomLine = hideClose ? region.closeLine - 1 : region.closeLine;
    if (hideTitle && bottomLine === titleLineNo) bottomLine = titleLineNo! - 1;
    // CM6 drops a line decoration on a line merged into another visual row, so
    // skip lines another plugin collapsed.
    while (bottomLine > region.openLine && lineCollapsed(state, bottomLine)) bottomLine--;

    for (let n = region.openLine; n <= region.closeLine; n++) {
      if (n === region.closeLine && hideClose) continue; // no row for a collapsed fence
      if (n === titleLineNo && hideTitle) continue; // no row for a collapsed title
      const line = doc.line(n);
      let cls = typeClass;
      if (n === region.openLine) cls += ' cm-callout-top';
      if (n === bottomLine) cls += ' cm-callout-bottom';
      const chip =
        !conceal && n === region.openLine && region.label && region.number != null
          ? { 'data-callout': `${region.label} ${region.number}` }
          : null;
      decos.push({
        from: line.from,
        to: line.from,
        deco: Decoration.line(chip ? { class: cls, attributes: chip } : { class: cls }),
      });
    }

    if (hideTitle && titleLineNo != null) {
      const range = collapsedLineRange(doc, titleLineNo);
      decos.push({ from: range.from, to: range.to, deco: HIDE });
    }

    if (conceal && !lineRevealed(cursor, openLine.from, openLine.to) && openLine.from < openLine.to) {
      const widget = new CalloutLabelWidget(
        region.label,
        region.number != null ? String(region.number) : '',
        region.title,
        region.refId ?? null,
      );
      decos.push({
        from: openLine.from,
        to: openLine.to,
        deco: Decoration.replace({ widget }),
      });
    }

    if (hideClose) {
      const range = closingFenceHideRange(doc, region);
      decos.push({ from: range.from, to: range.to, deco: HIDE });
    }

    if (!conceal) {
      // The title keeps the widget's styling: italic, or label weight for
      // beamer blocks whose title is the label.
      const title = titleRangeOnLine(openLine, region);
      const dimOpen = (from: number, to: number): void => {
        if (from < to) decos.push({ from, to, deco: SYNTAX_DIM });
      };
      if (title) {
        dimOpen(openLine.from, title.from);
        decos.push({ from: title.from, to: title.to, deco: region.label ? TITLE_MARK : LABEL_MARK });
        dimOpen(title.to, openLine.to);
      } else {
        dimOpen(openLine.from, openLine.to);
      }
      if (closeLine.from < closeLine.to) {
        decos.push({ from: closeLine.from, to: closeLine.to, deco: SYNTAX_DIM });
      }
    }
  }

  return Decoration.set(
    decos.map((d) => d.deco.range(d.from, d.to)),
    true,
  );
}

/** Decorations StateField for one language's scanner. A StateField, not a
 *  ViewPlugin: the fence hide replaces a line break, which CM6 forbids from
 *  plugins. */
export function makeCalloutField(
  scan: ScanCallouts,
  lineCollapsed?: LineCollapsed,
  opts: CalloutOptions = {},
): Extension {
  // One gate per field: a pointer-placed caret must not reflow the box
  // mid-gesture (reveal-gate.ts). Mixed collapses nothing, so its build reads
  // no selection (callers pass a `lineCollapsed` that is always false there).
  const gate = createRevealGate(
    (opts.conceal ?? true) ? {} : { selectionIndependent: () => true },
  );
  const field = StateField.define<DecorationSet>({
    create(state) {
      return buildCalloutDecorations(state, scan, lineCollapsed, opts);
    },
    update(decos, tr) {
      if (gate.decide(revealSignal(tr)) !== 'rebuild') return decos.map(tr.changes);
      return buildCalloutDecorations(tr.state, scan, lineCollapsed, opts);
    },
    provide: (f) => EditorView.decorations.from(f),
  });
  return [field];
}
