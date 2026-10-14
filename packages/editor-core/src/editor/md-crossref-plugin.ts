import {
  Decoration,
  DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
  WidgetType,
} from '@codemirror/view';
import { Extension, RangeSetBuilder } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import { crossrefIndex } from './crossref-index';
import { NUMBERED_PREFIX, UNNUMBERED_PREFIX } from './md-callout-plugin';
import { revealReplacedSourceInclusive } from './reveal';
import { concealOverridden } from './pointer-gesture';
import { createRevealGate, revealSignal } from './reveal-gate';
import '../styles/editor.css';

interface CrossrefOptions {
  /** `false` (Mixed): a resolved `@key` stays as source, marked
   *  `cm-crossref-key`, and never reveals. Default: the pill. */
  conceal?: boolean;
}

// Quarto `@key` (and suppressed-prefix `-@key`) references resolved against
// `crossrefIndex` render as a pill of the key; unknown keys stay as source in
// an "unresolved" style. The prefix allowlist keeps `$a @ b$` out; matches in
// math or code are skipped (OPAQUE).

// `tbl`/`lst` are Quarto prefixes nothing defines yet, so always unresolved.
const KINDS = [
  'sec',
  'eq',
  ...Object.keys(NUMBERED_PREFIX),
  ...Object.keys(UNNUMBERED_PREFIX),
  'tbl',
  'lst',
].join('|');
// Group 1: the suppress marker. Group 2: the key. The lookbehind rejects
// `@` inside a word and an escaped `\@`.
const REF = new RegExp(`(?<![\\w\\\\])(-?)@((?:${KINDS})-[\\w-]+)`, 'g');

class CrossrefWidget extends WidgetType {
  constructor(readonly text: string) {
    super();
  }

  eq(other: CrossrefWidget): boolean {
    return other.text === this.text;
  }

  toDOM(): HTMLElement {
    const span = document.createElement('span');
    // The KEY, not "Prefix Number", like the tex `\ref` pill: for unnumbered
    // kinds (proof, remark) a resolved label would name no particular one.
    span.className = 'cm-crossref cm-md-ref-pill';
    span.textContent = this.text;
    return span;
  }

  ignoreEvent(): boolean {
    return false; // a click places the caret, revealing the source
  }
}

const KEY_MARK = Decoration.mark({ class: 'cm-crossref-key' });
const UNRESOLVED_MARK = Decoration.mark({ class: 'cm-crossref-unresolved' });

const OPAQUE = new Set([
  'InlineMath',
  'InlineDisplayMath',
  'DisplayMath',
  'InlineCode',
  'FencedCode',
  'CodeBlock',
]);

function inOpaqueNode(tree: ReturnType<typeof syntaxTree>, pos: number): boolean {
  for (let n: ReturnType<typeof tree.resolveInner> | null = tree.resolveInner(pos); n; n = n.parent) {
    if (OPAQUE.has(n.name)) return true;
  }
  return false;
}

function buildCrossrefDecorations(view: EditorView, opts: CrossrefOptions = {}): DecorationSet {
  const conceal = opts.conceal ?? true;
  const { state } = view;
  const cursor = state.selection.main;
  // Stay concealed while a double-click runs against pre-reveal geometry.
  const overridden = concealOverridden(state);
  const index = crossrefIndex(state.doc);
  const builder = new RangeSetBuilder<Decoration>();
  const tree = syntaxTree(state);

  for (const { from, to } of view.visibleRanges) {
    const text = state.doc.sliceString(from, to);
    REF.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = REF.exec(text)) !== null) {
      const start = from + m.index;
      const end = start + m[0].length;
      if (inOpaqueNode(tree, start)) continue;

      const entry = index.get(m[2]);

      if (!entry) {
        builder.add(start, end, UNRESOLVED_MARK);
        continue;
      }
      if (!conceal) {
        builder.add(start, end, KEY_MARK);
        continue;
      }
      // End-inclusive: the caret right after the key is where you edit its
      // tail, so the source must stay revealed there.
      if (!overridden && revealReplacedSourceInclusive(cursor, start, end)) continue;
      builder.add(start, end, Decoration.replace({ widget: new CrossrefWidget(m[2]) }));
    }
  }

  return builder.finish();
}

function makeCrossrefViewPlugin(opts: CrossrefOptions = {}) {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;
      // Mixed reads no selection: the reveal check is Preview-only.
      private readonly gate = createRevealGate(
        (opts.conceal ?? true) ? {} : { selectionIndependent: () => true },
      );

      constructor(view: EditorView) {
        this.decorations = buildCrossrefDecorations(view, opts);
      }

      update(update: ViewUpdate) {
        const alsoRebuild =
          update.viewportChanged ||
          syntaxTree(update.state) !== syntaxTree(update.startState);
        if (this.gate.decide(revealSignal(update), alsoRebuild) !== 'rebuild') return;
        this.decorations = buildCrossrefDecorations(update.view, opts);
      }
    },
    { decorations: (v) => v.decorations },
  );
}

export function mdCrossrefPlugin(opts: CrossrefOptions = {}): Extension {
  return [makeCrossrefViewPlugin(opts)];
}
