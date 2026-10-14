import { syntaxTree } from '@codemirror/language';
import {
  Compartment,
  EditorState,
  Facet,
  type Extension,
  type Range,
} from '@codemirror/state';
import {
  Decoration,
  DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
} from '@codemirror/view';
import { hangingIndentSkip } from './hanging-indent';
import { concealOverridden } from './pointer-gesture';
import { HIDE, lineRevealed } from './reveal';
import { createRevealGate, revealSignal } from './reveal-gate';
import '../styles/list-layout.css';

// ---------------------------------------------------------------------------
//  Typeset Markdown (`editor-config.markdownStyle: 'typeset'`, the LaTeX
//  theme): Preview reads like a typeset page instead of styled source.
//  - Lists are laid out by depth: every line of a list item hangs by its
//    depth in em and source indentation is hidden, so wrapped rows and
//    continuation lines line up with the item text in any font. The marker
//    stays its source text (`-`, `1.`) at the start of the hang, so a nested
//    marker sits under its parent's text, as in the source.
//  - Quotes are an indented block with a rule; `> ` hides unless the caret is
//    on that line.
//  Lines a list shares with code, math or a quote keep the source layout.
//  Mixed and Source never load this plugin, and 'source' style renders
//  nothing.
// ---------------------------------------------------------------------------

/** Whether Markdown renders typeset. Set from editor-config through
 *  `markdownTypesetCompartment` (mount.ts / setup.ts). */
export const markdownTypeset = Facet.define<boolean, boolean>({
  combine: (values) => values.some(Boolean),
});

export const markdownTypesetCompartment = new Compartment();

export function markdownTypesetExtension(style: 'source' | 'typeset'): Extension {
  return style === 'typeset' ? markdownTypeset.of(true) : [];
}

interface ListLine {
  depth: number;
  /** Set on an item's first line: the source marker and its trailing space
   *  run from `markFrom` to `contentFrom`; the indent before it is hidden. */
  item?: { markFrom: number; contentFrom: number };
}

/** A typeset Markdown list line's hang at `depth`, in em: about a marker and
 *  its space per level, so the list barely moves from the source layout. */
function mdListHangEm(depth: number): number {
  return 1.1 * depth;
}

/** Node names whose lines keep their source layout inside a list. */
const KEEP_SOURCE = new Set(['FencedCode', 'CodeBlock', 'DisplayMath', 'Blockquote', 'HTMLBlock', 'Table']);

/** Typeset layout of every list line, from the syntax tree. Memoized on the
 *  tree, which is replaced whenever the doc or the parse changes. */
const layoutCache = new WeakMap<ReturnType<typeof syntaxTree>, ReadonlyMap<number, ListLine>>();

export function mdListLayout(state: EditorState): ReadonlyMap<number, ListLine> {
  const tree = syntaxTree(state);
  const hit = layoutCache.get(tree);
  if (hit) return hit;
  const { doc } = state;
  const lines = new Map<number, ListLine>();
  const keepSource = new Set<number>();

  tree.iterate({
    enter(node) {
      if (KEEP_SOURCE.has(node.name)) {
        const first = doc.lineAt(node.from).number;
        const last = doc.lineAt(Math.max(node.from, node.to - 1)).number;
        for (let n = first; n <= last; n++) keepSource.add(n);
        // A list inside a quote is the quote's: its lines start with `>`.
        return node.name === 'Blockquote' ? false : undefined;
      }
      if (node.name !== 'ListItem') return;
      let depth = 0;
      for (let p = node.node.parent; p; p = p.parent) {
        if (p.name === 'BulletList' || p.name === 'OrderedList') depth++;
      }
      const first = doc.lineAt(node.from);
      const last = doc.lineAt(Math.max(node.from, node.to - 1)).number;
      // Inner items are entered after their parent, so their lines take the
      // deeper depth.
      for (let n = first.number; n <= last; n++) lines.set(n, { depth });
      const mark = node.node.getChild('ListMark');
      if (!mark || doc.lineAt(mark.from).number !== first.number) return;
      const after = /^[ \t]*/.exec(doc.sliceString(mark.to, first.to))![0].length;
      lines.set(first.number, { depth, item: { markFrom: mark.from, contentFrom: mark.to + after } });
    },
  });

  for (const n of keepSource) lines.delete(n);
  layoutCache.set(tree, lines);
  return lines;
}

/** The source marker, filling the hang (list-layout.css). */
const ITEM_MARK = Decoration.mark({ class: 'cm-md-item-mark' });
const QUOTE_LINE = Decoration.line({ class: 'cm-md-quote-line' });

function lineDeco(depth: number, item: boolean): Decoration {
  return Decoration.line({
    class: item ? 'cm-md-list-line cm-md-list-item' : 'cm-md-list-line cm-md-list-cont',
    // The marker starts one step in from the hang (list-layout.css).
    attributes: {
      style: `--chalk-hang:${mdListHangEm(depth)}em;--chalk-md-list-outer:${mdListHangEm(depth - 1)}em`,
    },
  });
}

function build(view: EditorView): DecorationSet {
  const { state } = view;
  if (!state.facet(markdownTypeset)) return Decoration.none;
  const { doc } = state;
  const main = state.selection.main;
  // A double-click conceals everything for its duration (pointer-gesture.ts).
  const overridden = concealOverridden(state);
  const ranges: Range<Decoration>[] = [];

  // Quotes: one line class per line, the `> ` marks hidden off the caret line.
  const quoteLines = new Set<number>();
  for (const { from, to } of view.visibleRanges) {
    syntaxTree(state).iterate({
      from,
      to,
      enter(node) {
        if (node.name !== 'QuoteMark') return;
        const line = doc.lineAt(node.from);
        if (!quoteLines.has(line.number)) {
          quoteLines.add(line.number);
          ranges.push(QUOTE_LINE.range(line.from));
        }
        if (!overridden && lineRevealed(main, line.from, line.to)) return;
        const after = /^[ \t]?/.exec(doc.sliceString(node.to, line.to))![0].length;
        ranges.push(HIDE.range(node.from, node.to + after));
      },
    });
  }

  // Lists.
  const layout = mdListLayout(state);
  for (const { from, to } of view.visibleRanges) {
    for (let n = doc.lineAt(from).number, end = doc.lineAt(to).number; n <= end; n++) {
      const entry = layout.get(n);
      if (!entry) continue;
      const line = doc.line(n);
      ranges.push(lineDeco(entry.depth, entry.item !== undefined).range(line.from));
      if (entry.item) {
        const { markFrom, contentFrom } = entry.item;
        if (markFrom > line.from) ranges.push(HIDE.range(line.from, markFrom));
        ranges.push(ITEM_MARK.range(markFrom, contentFrom));
      } else {
        const indent = /^[ \t]*/.exec(line.text)![0].length;
        if (indent > 0 && indent < line.length) ranges.push(HIDE.range(line.from, line.from + indent));
      }
    }
  }
  return Decoration.set(ranges, true);
}

const typesetPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    private readonly gate = createRevealGate();

    constructor(view: EditorView) {
      this.decorations = build(view);
    }

    update(update: ViewUpdate) {
      const alsoRebuild =
        update.viewportChanged ||
        syntaxTree(update.state) !== syntaxTree(update.startState) ||
        update.startState.facet(markdownTypeset) !== update.state.facet(markdownTypeset);
      if (this.gate.decide(revealSignal(update), alsoRebuild) !== 'rebuild') return;
      this.decorations = build(update.view);
    }
  },
  { decorations: (v) => v.decorations },
);

/** Typeset list lines lay themselves out: hanging-indent.ts leaves them alone. */
const skipHang = hangingIndentSkip.of((state) => {
  if (!state.facet(markdownTypeset)) return () => false;
  const layout = mdListLayout(state);
  return (line) => layout.has(line);
});

/** Preview only: Mixed must not hide anything (view-mode.ts). */
export function mdTypesetPlugin(): Extension {
  return [typesetPlugin, skipHang];
}
