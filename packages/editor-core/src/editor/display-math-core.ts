import {
  Decoration,
  DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
  WidgetType,
  keymap,
} from '@codemirror/view';
import {
  EditorSelection,
  EditorState,
  Extension,
  Prec,
  RangeSetBuilder,
  StateEffect,
  StateField,
  Text,
  Transaction,
} from '@codemirror/state';
import { KaTeXCache, countSourceEquationNumbers } from '../utils/katex-cache';
import {
  blockReplaceFrom,
  displayPreviewPos,
  sameColumnOnLine,
  dispatchVerticalStop,
  moreWrappedRows,
  type ScanCallouts,
} from './callout-core';
import { concealOverridden, isGestureEffect, recentTouch } from './pointer-gesture';
import { createRevealGate, revealSignal } from './reveal-gate';
import { lineRevealed, revealReplacedSource } from './reveal';

// ---------------------------------------------------------------------------
//  Language-neutral display-math field
//
//  tex and md find their math differently (scanMathRegions vs Lezer nodes) and
//  render a settled block differently; each passes a region provider and a
//  settled render. Everything in between (reveal rule, debounced preview,
//  equation offsets, callout hand-off, click-to-open, Up/Down stop) lives here
//  once: put fixes here, not in one language.
//
//  Five region shapes across the two languages:
//
//    language  construct              display  block
//    tex       `$$…$$` `\[…\]` env      yes      yes
//    tex       `$…$` `\(…\)`             no       no
//    md        DisplayMath              yes      yes
//    md        InlineDisplayMath        yes      no
//    md        InlineMath (wrapped)      no       no
//
//  `display`: live preview while edited, counts toward the equation offset.
//  `block`: whole-line block replace, line-based reveal, Up/Down stop. They
//  differ only for md's paragraph-interior `$$…$$`.
// ---------------------------------------------------------------------------

/** One math construct as the shared field sees it. */
export interface DisplayMathRegion {
  /** Document offset of the opening delimiter. */
  from: number;
  /** Document offset one past the closing delimiter. */
  to: number;
  /** The LaTeX fed to KaTeX for the preview and counted for equation numbers. */
  content: string;
  /** Live preview below while revealed; counts toward the equation offset. */
  display: boolean;
  /** Whole-line construct: block replace, line-based reveal, arrow-key stop.
   *  Defaults to `display`. */
  block?: boolean;
  /** End handed to `displayPreviewPos` when the preview belongs below `to`
   *  (md's paragraph-interior form previews under the paragraph). */
  previewTo?: number;
  /** Optional decoration over the revealed source (md: `cm-math-editing`). */
  revealDeco?: Decoration;
}

/** Everything the shared debounced preview needs from its language. */
export interface DisplayMathPreviewOptions {
  /** KaTeX cache for the preview (tex: one per editor; md: shared). */
  cache: KaTeXCache;
  className: string;
  /** So a preview under a block that ends a callout lands past the collapsed
   *  close fence (see displayPreviewPos). */
  scanCallouts: ScanCallouts;
}

export interface DisplayMathOptions<R extends DisplayMathRegion> {
  /** Every math construct, sorted and non-overlapping (binary searches rely
   *  on both). */
  regionsOf(state: EditorState): readonly R[];
  /** The rendered widget for a region the caret is not in, plus the position
   *  it replaces THROUGH when it absorbs a collapsed fence (`hideTo`). */
  settled(
    state: EditorState,
    region: R,
    eqOffset: number,
  ): { widget: WidgetType; hideTo?: number };
  preview: DisplayMathPreviewOptions;
  /** Rendered-widget selector for the click-to-open handler. */
  widgetSelector: string;
  /** Place the caret at the REGION's start rather than at the widget's
   *  position, and ignore a click that resolves to no region (tex). */
  clickSnapsToRegionStart?: boolean;
  /** Whether the double-click conceal override also re-collapses a revealed
   *  whole-line block (md). tex opts out: re-collapsing mid-double-click would
   *  leave the second click selecting invisible text. */
  blockObeysConcealOverride?: boolean;
  /** True when a line construct besides callouts, whose collapse the settled
   *  render reads from the selection (tex: list fences), sits on a line
   *  `nearLine` accepts. See selectionRebuildRequired. */
  fenceNearCaret?(doc: Text, nearLine: (line: number) => boolean): boolean;
  /** Forces a rebuild when something the reveal gate can't see moved (md: the
   *  background parse advanced the tree). */
  alsoRebuild?(tr: Transaction): boolean;
}

/**
 * The debounced preview state, one slot per editor instance (never module
 * level: a second editor would clear it). One slot suffices: only the caret's
 * region can be mid-edit.
 */
interface PreviewSlot {
  // Last successful render of the region being edited: the fallback while its
  // source is invalid. Keying by the (invalid) current content could never hit.
  lastValid: string;
  // Source the preview shows. A keystroke advances it while `lastCost` is
  // within SYNC_PREVIEW_BUDGET_MS; past that, only the debouncer or a caret
  // move does.
  content: string | null;
  // Milliseconds the last preview render took.
  lastCost: number;
  // The preview shows older source than its region: the debouncer must fire.
  stale: boolean;
}

/**
 * A keystroke re-renders the preview in the same transaction while the last
 * render took at most this. A slower formula waits for the 150ms debouncer,
 * so a long `align` on a slow device can't stall typing.
 */
const SYNC_PREVIEW_BUDGET_MS = 4;

/**
 * Live preview below a display region while the caret is inside it. Shows
 * `lastValidHtml` when the current source fails, so it doesn't flicker.
 */
class MathPreviewWidget extends WidgetType {
  constructor(
    private readonly className: string,
    private readonly content: string,
    private readonly lastValidHtml: string,
    private readonly cache: KaTeXCache,
    private readonly eqOffset: number,
  ) {
    super();
  }

  eq(other: MathPreviewWidget): boolean {
    return (
      this.className === other.className &&
      this.content === other.content &&
      this.lastValidHtml === other.lastValidHtml &&
      this.eqOffset === other.eqOffset
    );
  }

  private paint(host: HTMLElement): void {
    host.style.setProperty('--chalk-eq-offset', String(this.eqOffset));
    host.innerHTML = this.cache.render(this.content, true) ?? this.lastValidHtml;
  }

  toDOM(): HTMLElement {
    const host = document.createElement('div');
    host.className = this.className;
    host.setAttribute('contenteditable', 'false');
    this.paint(host);
    return host;
  }

  updateDOM(dom: HTMLElement): boolean {
    this.paint(dom);
    return true;
  }

  ignoreEvent(): boolean {
    // Read-only: events go to the source above.
    return true;
  }
}

/** Asks every installed display-math field to advance its debounced preview.
 *  One effect for both languages: a document is one language, and the two
 *  view-mode compartments of one language never run at once. */
const requestPreviewUpdate = StateEffect.define<null>();

/**
 * Test instrumentation: full rebuilds. Caret moves far from math and fences
 * must keep the existing set.
 */
let mathBuilds = 0;
export function __mathBuildCount(): number {
  return mathBuilds;
}
export function __resetMathBuildCount(): void {
  mathBuilds = 0;
}

/**
 * Index of the first region ending past `pos` (`to > pos`). Regions are sorted
 * and non-overlapping, so every region before it ends at or before `pos`.
 */
function firstRegionEndingAfter(regions: readonly DisplayMathRegion[], pos: number): number {
  let lo = 0;
  let hi = regions.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (regions[mid].to > pos) hi = mid;
    else lo = mid + 1;
  }
  return lo;
}

/** The region containing `pos` (`from <= pos < to`), if any. */
export function regionAt<R extends DisplayMathRegion>(regions: readonly R[], pos: number): R | null {
  const r = regions[firstRegionEndingAfter(regions, pos)];
  return r && r.from <= pos ? r : null;
}

/** Whether some region touching the line passes `test`, in O(log n + k). */
function someRegionOnLine<R extends DisplayMathRegion>(
  regions: readonly R[],
  line: { from: number; to: number },
  test: (r: R) => boolean,
): boolean {
  for (
    let i = firstRegionEndingAfter(regions, line.from);
    i < regions.length && regions[i].from <= line.to;
    i++
  ) {
    if (test(regions[i])) return true;
  }
  return false;
}

/**
 * True when an empty caret at `pos` could influence the built set: inside an
 * inline region ([from, to), the reveal test), or on any line a whole-line
 * region touches (its line-based reveal).
 */
function nearMathRegion(doc: Text, regions: readonly DisplayMathRegion[], pos: number): boolean {
  return someRegionOnLine(
    regions,
    doc.lineAt(pos),
    (r) => (r.block ?? r.display) || (pos >= r.from && pos < r.to),
  );
}

/**
 * False only when moving the caret from `a` to `b` provably leaves the built
 * set unchanged; anything ambiguous rebuilds. Beyond "caret in math", a callout
 * fence's collapse decides `hideTo` and the box bottom of the block above it
 * (calloutBlockAt), so a caret near a callout fence or a `fenceNearCaret`
 * construct rebuilds. Non-empty selections always rebuild.
 */
function selectionRebuildRequired<R extends DisplayMathRegion>(
  opts: DisplayMathOptions<R>,
  a: EditorState,
  b: EditorState,
): boolean {
  const oldSel = a.selection.main;
  const newSel = b.selection.main;
  if (!oldSel.empty || !newSel.empty) return true;
  const doc = b.doc; // no doc change on this path
  const regions = opts.regionsOf(b);
  if (nearMathRegion(doc, regions, oldSel.head) || nearMathRegion(doc, regions, newSel.head)) {
    return true;
  }
  const oldLine = doc.lineAt(oldSel.head).number;
  const newLine = doc.lineAt(newSel.head).number;
  const nearLine = (line: number) =>
    Math.abs(oldLine - line) <= 1 || Math.abs(newLine - line) <= 1;
  for (const c of opts.preview.scanCallouts(doc)) {
    if (nearLine(c.openLine) || nearLine(c.closeLine)) return true;
  }
  return opts.fenceNearCaret?.(doc, nearLine) ?? false;
}

/** Whole-line reveal for a block region (see `lineRevealed`). */
function blockRevealed(state: EditorState, from: number, to: number): boolean {
  const { doc } = state;
  return lineRevealed(
    state.selection.main,
    doc.lineAt(from).from,
    doc.lineAt(Math.max(from, to - 1)).to,
    blockReplaceFrom(doc, from),
    to,
  );
}

/**
 * Decorations for every math region: the language's widget, or the source
 * (plus a preview for display math) when revealed. Whole-document because
 * block decorations must come from a StateField, which has no visibleRanges.
 */
function buildDecorations<R extends DisplayMathRegion>(
  opts: DisplayMathOptions<R>,
  state: EditorState,
  preview: PreviewSlot,
  // False only for typing-triggered rebuilds: the preview then re-renders
  // only within SYNC_PREVIEW_BUDGET_MS, else keeps its content for the
  // debouncer.
  refreshPreview: boolean,
): DecorationSet {
  mathBuilds++;
  const { doc } = state;
  const main = state.selection.main;
  // Conceal everything while a double-click runs on pre-reveal geometry.
  const overridden = concealOverridden(state);
  let sawEditRegion = false;
  let stale = false;

  // Sorted before building: a preview widget at a region's end can coincide
  // with the next region's `from` (`\[a\]$b$`), and out-of-order input makes
  // RangeSetBuilder throw and kill the field update.
  const decos: { from: number; to: number; deco: Decoration }[] = [];

  // Equation numbers emitted so far; each widget restarts KaTeX's counters from
  // it, so numbering survives CM6's virtualization. Counted from source so the
  // build never renders off-screen regions.
  let eqOffset = 0;

  for (const region of opts.regionsOf(state)) {
    const block = region.block ?? region.display;
    // Block: revealed by a caret on any of its lines or a selection that
    // started there (shift-down past `$$` must not collapse it mid-selection).
    // Inline: revealed by a caret or selection wholly inside; one crossing an
    // edge renders, so it never reflows text under a drag highlight.
    const revealed = block
      ? (!opts.blockObeysConcealOverride || !overridden) &&
        blockRevealed(state, region.from, region.to)
      : !overridden && revealReplacedSource(main, region.from, region.to);

    if (revealed) {
      if (region.revealDeco) {
        decos.push({ from: region.from, to: region.to, deco: region.revealDeco });
      }
      // No preview for inline math: it would shove text around per keystroke.
      if (region.display) {
        sawEditRegion = true;
        if (
          refreshPreview ||
          preview.content === null ||
          preview.lastCost <= SYNC_PREVIEW_BUDGET_MS
        ) {
          preview.content = region.content;
          const start = performance.now();
          const html = opts.preview.cache.render(region.content, true);
          preview.lastCost = performance.now() - start;
          if (html) preview.lastValid = html;
        }
        stale ||= preview.content !== region.content;
        // Past a collapsed callout close fence, so its hide keeps its merge
        // host (no phantom row).
        const previewPos = displayPreviewPos(
          doc,
          opts.preview.scanCallouts,
          region.from,
          region.previewTo ?? region.to,
          main,
        );
        decos.push({
          from: previewPos,
          to: previewPos,
          deco: Decoration.widget({
            widget: new MathPreviewWidget(
              opts.preview.className,
              preview.content,
              preview.lastValid,
              opts.preview.cache,
              eqOffset,
            ),
            block: true,
            side: 1,
          }),
        });
      }
    } else {
      const { widget, hideTo } = opts.settled(state, region, eqOffset);
      decos.push({
        // Block replaces start at the line start, or an indent is left as a
        // stray `.cm-line` (blockReplaceFrom).
        from: block ? blockReplaceFrom(doc, region.from) : region.from,
        to: hideTo ?? region.to,
        deco: Decoration.replace({ widget, block }),
      });
    }

    if (region.display) eqOffset += countSourceEquationNumbers(region.content);
  }

  if (!sawEditRegion) {
    // Nothing mid-edit: the next region starts from its own content.
    preview.content = null;
    preview.lastValid = '';
    preview.lastCost = 0;
  }
  preview.stale = stale;

  decos.sort((a, b) => a.from - b.from || a.to - b.to);
  const builder = new RangeSetBuilder<Decoration>();
  for (const { from, to, deco } of decos) {
    builder.add(from, to, deco);
  }
  return builder.finish();
}

/**
 * The display-math field, preview debouncer and click handler for one language.
 * Call once per editor instance: the preview slot and reveal gate must not be
 * shared between editors.
 */
export function displayMathField<R extends DisplayMathRegion>(
  opts: DisplayMathOptions<R>,
): Extension {
  const preview: PreviewSlot = { lastValid: '', content: null, lastCost: 0, stale: false };
  const gate = createRevealGate({
    selectionIndependent: (a, b) => !selectionRebuildRequired(opts, a, b),
  });

  // Block replaces must come from a StateField; inline math shares it.
  const field = StateField.define<DecorationSet>({
    create(state) {
      return buildDecorations(opts, state, preview, true);
    },
    update(decos, tr) {
      const previewFx = tr.effects.some((e) => e.is(requestPreviewUpdate));
      const alsoRebuild = previewFx || (opts.alsoRebuild?.(tr) ?? false);
      if (gate.decide(revealSignal(tr), alsoRebuild) !== 'rebuild') {
        return decos.map(tr.changes);
      }
      // Typing refreshes the preview only within budget; caret moves, the
      // debouncer and a gesture settle always do.
      return buildDecorations(
        opts,
        tr.state,
        preview,
        !tr.docChanged || previewFx || tr.effects.some(isGestureEffect),
      );
    },
    provide: (f) => [
      EditorView.decorations.from(f),
      // NOT atomicRanges: the caret would skip the whole region on arrows.
      // Arrows step in one position at a time and the reveal uncollapses it.
    ],
  });

  // 150ms after the last keystroke that left the preview behind its source
  // (a render over budget), refresh it.
  const previewDebouncer = ViewPlugin.fromClass(
    class {
      private timer: ReturnType<typeof setTimeout> | null = null;

      update(update: ViewUpdate) {
        if (!update.docChanged) return;
        // Clear before the staleness check, or a shot scheduled before the
        // caret left the region still fires.
        if (this.timer) {
          clearTimeout(this.timer);
          this.timer = null;
        }
        // The field has already built this update's set, so `stale` is
        // current.
        if (!preview.stale) return;
        this.timer = setTimeout(() => {
          update.view.dispatch({ effects: requestPreviewUpdate.of(null) });
        }, 150);
      }

      destroy() {
        if (this.timer) clearTimeout(this.timer);
      }
    },
  );

  // Left-click on a rendered formula: caret to the region start, press consumed
  // so CM6 never starts a MouseSelection on the widget. Otherwise a right-half
  // click lands at the exclusive END (outside the inline reveal, a dead
  // click), and any tremor flips posAtCoords between the widget's two edges,
  // drag-selecting the whole source. Touch resolves positions structurally
  // and cannot drag, hence `recentTouch`.
  const mathWidgetMousedown = EditorView.domEventHandlers({
    mousedown(event, view) {
      if (event.button !== 0 || event.shiftKey || event.metaKey || event.ctrlKey) return false;
      if (recentTouch()) return false;
      const target = event.target;
      if (!(target instanceof Element)) return false;
      const el = target.closest(opts.widgetSelector);
      if (!el || !view.contentDOM.contains(el)) return false;
      // A press in a non-empty selection may start a drag: leave it to CM6.
      if (!view.state.selection.main.empty) return false;
      // `posAtDOM` on a replace widget returns its range start.
      let pos = view.posAtDOM(el as HTMLElement);
      if (opts.clickSnapsToRegionStart) {
        // Containment, not `r.from === pos`: a block replace starts at the
        // whole-line boundary, which can sit before the region's own `from`.
        const { doc } = view.state;
        const region = opts
          .regionsOf(view.state)
          .find((r) => pos >= ((r.block ?? r.display) ? blockReplaceFrom(doc, r.from) : r.from) && pos <= r.to);
        if (!region) return false;
        pos = region.from;
      }
      view.focus();
      view.dispatch({
        selection: EditorSelection.cursor(pos),
        userEvent: 'select.pointer',
      });
      return true;
    },
  });

  return [field, previewDebouncer, mathWidgetMousedown];
}

// ---------------------------------------------------------------------------
// Vertical arrow-key navigation into collapsed display math
// ---------------------------------------------------------------------------
//
// A collapsed block is one visual line, so `moveByLine` jumps over it and the
// source never reveals. Down on the line above (Up on the line below) lands
// on its opening (closing) line instead. Whole-line regions only.

export interface DisplayMathArrows {
  /** Down on the line above a collapsed block: same column, opening line. */
  fromAbove(view: EditorView): boolean;
  /** Up on the line immediately below a collapsed block. */
  fromBelow(view: EditorView): boolean;
  extension: Extension;
}

export function displayMathArrows(
  regionsOf: (state: EditorState) => readonly DisplayMathRegion[],
): DisplayMathArrows {
  function step(view: EditorView, dir: -1 | 1): boolean {
    const { state } = view;
    const sel = state.selection.main;
    if (!sel.empty) return false;
    // Adjacency is by DOCUMENT line: let a wrapped line finish its visual rows.
    if (moreWrappedRows(view, dir)) return false;

    const { doc } = state;
    const landing = doc.lineAt(sel.head).number + dir;
    if (landing < 1 || landing > doc.lines) return false;
    const line = doc.line(landing);
    // A block whose opening (Down) or closing (Up) line is the next line. A
    // collapsed callout fence in between is its own stop (makeFenceStopKeymap).
    const hit = someRegionOnLine(
      regionsOf(state),
      line,
      (r) =>
        (r.block ?? r.display) &&
        (dir === 1 ? r.from >= line.from : Math.max(r.from, r.to - 1) <= line.to),
    );
    if (!hit) return false;
    // dispatchVerticalStop keeps the goal column alive across the stop; a
    // bare dispatch lets it decay toward 0 over a run of presses.
    dispatchVerticalStop(view, sameColumnOnLine(state, sel.head, landing));
    return true;
  }

  const fromAbove = (view: EditorView) => step(view, 1);
  const fromBelow = (view: EditorView) => step(view, -1);

  return {
    fromAbove,
    fromBelow,
    extension: Prec.high(
      keymap.of([
        { key: 'ArrowDown', run: fromAbove },
        { key: 'ArrowUp', run: fromBelow },
      ]),
    ),
  };
}
