import {
  Decoration,
  DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
  WidgetType,
} from '@codemirror/view';
import {
  EditorSelection,
  EditorState,
  Extension,
  Range,
  SelectionRange,
} from '@codemirror/state';
import { styleRegionsFor } from './tex-decorations';
import type { TexStyleRegion } from './tex-style-incremental';
import { HIDE, revealDelimitedSource, revealReplacedSource, SYNTAX_DIM } from './reveal';
import {
  concealOverridden,
  recentTouch,
} from './pointer-gesture';
import { createRevealGate, revealSignal, type RevealGate } from './reveal-gate';
import { liveLinkClickHandler, liveLinkMark } from './live-link';
import '../styles/editor.css';

//  LaTeX syntax concealment: the preview counterpart to texDecorationsPlugin
//  (which marks arguments and stays on in source mode). This one hides the
//  syntax and must live inside previewCompartment. A caret inside a command
//  reveals its raw source.
//
//  All emitted ranges are single-line (a ViewPlugin replace across a line
//  break throws and disables the plugin), see `concealedShape`.

class TexPillWidget extends WidgetType {
  constructor(
    readonly text: string,
    readonly cls: string,
  ) {
    super();
  }

  eq(other: TexPillWidget): boolean {
    return other.text === this.text && other.cls === this.cls;
  }

  toDOM(): HTMLElement {
    const span = document.createElement('span');
    span.className = this.cls;
    span.textContent = this.text;
    return span;
  }

  ignoreEvent(): boolean {
    return false; // let a click place the caret so the raw command reveals
  }
}

/** Refs and labels show the key; cites join their keys in one parenthesised
 *  group (no .bib resolution). */
function pillText(r: TexStyleRegion, arg: string): string {
  if (r.kind === 'cite') {
    const keys = arg
      .split(',')
      .map((k) => k.trim())
      .filter(Boolean);
    return `(${keys.join('; ')})`;
  }
  return arg;
}

const PILL_CLASS: Partial<Record<TexStyleRegion['kind'], string>> = {
  ref: 'cm-tex-ref-pill',
  cite: 'cm-tex-ref-pill',
  label: 'cm-tex-label-pill',
};

const SECTION_LEVEL: Record<string, number> = { section: 1, subsection: 2, subsubsection: 3 };

// Memoized on the regions array identity, which only changes with the doc.
const regionNumbersMemo = new WeakMap<readonly TexStyleRegion[], Map<TexStyleRegion, string>>();

/** Section numbers ("2.1.3"; starred forms neither show nor advance a
 *  counter, as in LaTeX) and footnote numbers, keyed by region identity. */
function regionNumbers(regions: readonly TexStyleRegion[]): Map<TexStyleRegion, string> {
  const memoized = regionNumbersMemo.get(regions);
  if (memoized) return memoized;
  const numbers = new Map<TexStyleRegion, string>();
  const counters = [0, 0, 0];
  let footnotes = 0;
  for (const r of regions) {
    if (r.kind === 'footnote') {
      numbers.set(r, String(++footnotes));
      continue;
    }
    const level = SECTION_LEVEL[r.name];
    if (!level || r.starred) continue;
    counters[level - 1]++;
    for (let l = level; l < counters.length; l++) counters[l] = 0;
    numbers.set(r, counters.slice(0, level).join('.'));
  }
  regionNumbersMemo.set(regions, numbers);
  return numbers;
}

function sameLine(state: EditorState, from: number, to: number): boolean {
  return state.doc.lineAt(from).number === state.doc.lineAt(to).number;
}

/** Kinds whose concealed form is a widget REPLACING the whole command; the
 *  rest hide only `\cmd{` and `}`. The reveal rule depends on the difference. */
const COLLAPSES_WHOLE: ReadonlySet<TexStyleRegion['kind']> = new Set([
  'ref',
  'cite',
  'label',
  'footnote',
]);

/**
 * What Preview hides of region `r` while not revealed: `'whole'` (a widget
 * replaces `\cmd{…}`), `'delimiters'` (`\cmd{` and `}` hidden) or null (raw).
 * The build and tex-vertical-motion both read it, so they can't disagree.
 */
export function concealedShape(
  state: EditorState,
  r: TexStyleRegion,
): 'whole' | 'delimiters' | null {
  if (r.from === r.to) return null; // empty argument: leave the source visible
  // A ViewPlugin may not replace across a line break: a pill needs the whole
  // command on one line, and \href's prefix swallows its url argument.
  if (COLLAPSES_WHOLE.has(r.kind)) return sameLine(state, r.cmdFrom, r.to + 1) ? 'whole' : null;
  if (r.kind === 'href' || r.kind === 'url') {
    return sameLine(state, r.cmdFrom, r.from) ? 'delimiters' : null;
  }
  return 'delimiters';
}

/**
 * The one reveal decision per region, shared by the build and by
 * `concealSelectionIndependent` so the two can never disagree. A caret inside
 * reveals. A SELECTION reveals only when an end would be stranded inside a
 * replaced range (a replace has no DOM position to hold it); a selection on
 * the visible argument, as a double-click makes, keeps the concealed form.
 */
function regionRevealed(main: SelectionRange, r: TexStyleRegion): boolean {
  const end = r.to + 1; // past the closing brace
  return COLLAPSES_WHOLE.has(r.kind)
    ? revealReplacedSource(main, r.cmdFrom, end)
    : revealDelimitedSource(main, r.cmdFrom, end, r.from, r.to);
}

/**
 * True when a selection-only update cannot change the built set. Given the doc
 * and the conceal override (checked by the reveal gate), the build depends only
 * on one reveal boolean per region, so equal booleans mean an identical set.
 */
function concealSelectionIndependent(a: EditorState, b: EditorState): boolean {
  const oldCursor = a.selection.main;
  const newCursor = b.selection.main;
  for (const r of styleRegionsFor(b)) {
    if (r.from === r.to) continue;
    if (regionRevealed(oldCursor, r) !== regionRevealed(newCursor, r)) return false;
  }
  return true;
}

/** Instrumentation: counts full rebuilds, so a test can assert that caret moves
 *  that change no reveal keep the existing set. */
let concealBuilds = 0;
export function __concealBuildCount(): number {
  return concealBuilds;
}
export function __resetConcealBuildCount(): void {
  concealBuilds = 0;
}

/** Mixed (`conceal: false`): dim `\cmd{` and `}` instead of hiding them. No
 *  widgets, no reveal checks. href/url keep the `cm-live-link` mark so
 *  Cmd+click still works. */
function buildDimDecorations(state: EditorState): DecorationSet {
  const regions = styleRegionsFor(state);
  const ranges: Range<Decoration>[] = [];
  for (const r of regions) {
    if (r.from === r.to) continue; // empty argument: leave the source visible
    const end = r.to + 1; // past the closing brace
    ranges.push(SYNTAX_DIM.range(r.cmdFrom, r.from));
    if (r.kind === 'href' || r.kind === 'url') {
      ranges.push(liveLinkMark(r.url ?? '').range(r.from, r.to));
    }
    ranges.push(SYNTAX_DIM.range(r.to, end));
  }
  return Decoration.set(ranges, true);
}

function buildConcealDecorations(view: EditorView, opts: TexConcealOptions = {}): DecorationSet {
  concealBuilds++;
  const { state } = view;
  if (!(opts.conceal ?? true)) return buildDimDecorations(state);
  const cursor = state.selection.main;
  const regions = styleRegionsFor(state);
  const numbers = regionNumbers(regions);
  const ranges: Range<Decoration>[] = [];
  // Double-click undo: conceal regardless of caret position, restoring the
  // pre-reveal geometry the second click was aimed at (pointer-gesture.ts).
  const overridden = concealOverridden(state);

  // End of the last whole-command replace: regions nested inside it must not
  // emit (overlapping replaces can throw).
  let collapsedUntil = -1;

  for (const r of regions) {
    if (r.cmdFrom < collapsedUntil) continue;
    if (!concealedShape(state, r)) continue;
    const end = r.to + 1; // past the closing brace
    if (!overridden && regionRevealed(cursor, r)) continue;

    switch (r.kind) {
      case 'strong':
      case 'em':
      case 'tt':
      case 'underline':
      case 'sc':
      case 'runin':
      case 'caption':
      // No number widget for frame titles: the slide number belongs to the card.
      case 'frametitle':
      case 'framesubtitle': {
        ranges.push(HIDE.range(r.cmdFrom, r.from));
        ranges.push(HIDE.range(r.to, end));
        break;
      }
      case 'h1':
      case 'h2':
      case 'h3': {
        const num = numbers.get(r);
        const prefix = num
          ? Decoration.replace({
              widget: new TexPillWidget(num, `cm-tex-secnum cm-h${SECTION_LEVEL[r.name]}`),
            })
          : HIDE;
        ranges.push(prefix.range(r.cmdFrom, r.from));
        ranges.push(HIDE.range(r.to, end));
        break;
      }
      case 'ref':
      case 'cite':
      case 'label': {
        const arg = state.doc.sliceString(r.from, r.to);
        ranges.push(
          Decoration.replace({
            widget: new TexPillWidget(pillText(r, arg), PILL_CLASS[r.kind]!),
          }).range(r.cmdFrom, end),
        );
        collapsedUntil = end;
        break;
      }
      case 'footnote': {
        ranges.push(
          Decoration.replace({
            widget: new TexPillWidget(numbers.get(r)!, 'cm-tex-footnote-mark'),
          }).range(r.cmdFrom, end),
        );
        collapsedUntil = end;
        break;
      }
      case 'href':
      case 'url': {
        ranges.push(HIDE.range(r.cmdFrom, r.from));
        ranges.push(liveLinkMark(r.url ?? '').range(r.from, r.to));
        ranges.push(HIDE.range(r.to, end));
        break;
      }
    }
  }

  // Nested commands interleave, which RangeSetBuilder rejects: let
  // Decoration.set sort.
  return Decoration.set(ranges, true);
}

const PILL_SELECTOR = '.cm-tex-ref-pill, .cm-tex-label-pill, .cm-tex-footnote-mark';

class TexConcealPluginValue {
  decorations: DecorationSet;
  /** Owns the pointer freeze (reveal-gate.ts) and the selection-independence
   *  shortcut. Mixed reveals nothing, so its set is selection-independent. */
  private readonly gate: RevealGate;

  constructor(
    readonly view: EditorView,
    private readonly opts: TexConcealOptions,
  ) {
    this.gate = createRevealGate({
      selectionIndependent: (opts.conceal ?? true) ? concealSelectionIndependent : () => true,
    });
    this.decorations = buildConcealDecorations(view, opts);
  }

  update(update: ViewUpdate) {
    if (this.gate.decide(revealSignal(update)) !== 'rebuild') return;
    this.decorations = buildConcealDecorations(update.view, this.opts);
  }

  /** Left-click on a pill: CM6 would put the caret at the range's exclusive
   *  END for a right-half click (a dead zone). Place it on the key instead, as
   *  a pointer selection, so the reveal fires on button release. */
  handlePillMouseDown(event: MouseEvent): boolean {
    if (event.button !== 0 || event.shiftKey || event.metaKey || event.ctrlKey) return false;
    // Touch-synthesized compat mousedown: the touch path has no dead zone.
    if (recentTouch()) return false;
    const el = (event.target as HTMLElement).closest(PILL_SELECTOR);
    if (!el || !this.view.contentDOM.contains(el)) return false;
    const pos = this.view.posAtDOM(el); // a replace widget's DOM → range start
    const region = styleRegionsFor(this.view.state).find((r) => r.cmdFrom === pos);
    if (!region) return false;
    const main = this.view.state.selection.main;
    // A press inside a selection may be a drag-and-drop: leave it to CM6.
    if (!main.empty && main.from <= region.to + 1 && main.to >= region.cmdFrom) return false;
    this.view.focus();
    this.view.dispatch({
      selection: EditorSelection.cursor(region.from),
      userEvent: 'select.pointer',
    });
    return true;
  }
}

function makeTexConcealViewPlugin(opts: TexConcealOptions) {
  return ViewPlugin.define((view) => new TexConcealPluginValue(view, opts), {
    decorations: (v) => v.decorations,
    eventHandlers: {
      mousedown(event) {
        return this.handlePillMouseDown(event);
      },
    },
  });
}

interface TexConcealOptions {
  /** `false` (Mixed): dim the syntax instead of hiding it. Default true. */
  conceal?: boolean;
}

export function texConcealPlugin(opts: TexConcealOptions = {}): Extension {
  return [makeTexConcealViewPlugin(opts), liveLinkClickHandler];
}
