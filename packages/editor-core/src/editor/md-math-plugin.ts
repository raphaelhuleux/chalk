import {
  Decoration,
  DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
  WidgetType,
} from '@codemirror/view';
import { EditorState, Extension, RangeSetBuilder, Text } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import { glueEnd } from './punctuation-glue';
import type { MarkdownConfig, InlineParser, InlineContext, BlockParser, BlockContext, Line } from '@lezer/markdown';
import { tags } from '@lezer/highlight';
import { KaTeXCache } from '../utils/katex-cache';
import { revealReplacedSource } from './reveal';
import { createRevealGate, revealSignal } from './reveal-gate';
import { concealOverridden } from './pointer-gesture';
import { calloutBlockAt, calloutTagClasses, sameCalloutTag, type CalloutTag } from './callout-core';
import {
  displayMathArrows,
  displayMathField,
  type DisplayMathRegion,
} from './display-math-core';
import { scanCallouts } from './md-callout-plugin';
import { crossrefIndex } from './crossref-index';
import '../styles/math.css';

/** The slice of a Lezer node these helpers need (`@lezer/common` is only a
 *  transitive dependency). */
interface MathNode {
  from: number;
  to: number;
  getChildren(name: string): Array<{ from: number; to: number }>;
}

const katexCache = new KaTeXCache();

// ---------------------------------------------------------------------------
//  Lezer InlineParser: teaches the markdown parser about $…$
// ---------------------------------------------------------------------------

const DOLLAR = 36;   // '$'.charCodeAt(0)
const BACKSLASH = 92; // '\'.charCodeAt(0)
const NEWLINE = 10;   // '\n'.charCodeAt(0)
const SPACE = 32;     // ' '.charCodeAt(0)
const TAB = 9;        // '\t'.charCodeAt(0)

/** Whether the newline at `nl` starts a blank line (or ends the block). */
function blankLineAfter(cx: InlineContext, nl: number): boolean {
  let k = nl + 1;
  while (k < cx.end && (cx.char(k) === SPACE || cx.char(k) === TAB)) k++;
  return k >= cx.end || cx.char(k) === NEWLINE;
}

const inlineMathParser: InlineParser = {
  name: 'InlineMath',

  parse(cx: InlineContext, next: number, pos: number): number {
    if (next !== DOLLAR) return -1;

    // `$$` belongs to the display parsers.
    if (cx.char(pos + 1) === DOLLAR) return -1;
    if (pos > cx.offset && cx.char(pos - 1) === DOLLAR) return -1;

    // Pandoc: the opening $ is followed by a non-space (`I paid $ 5` is prose).
    const afterOpen = cx.char(pos + 1);
    if (afterOpen === SPACE || afterOpen === TAB) return -1;

    let end = pos + 1;
    while (end < cx.end) {
      const ch = cx.char(end);

      if (ch === DOLLAR) {
        if (end + 1 < cx.end && cx.char(end + 1) === DOLLAR) {
          return -1;
        }

        if (end === pos + 1) return -1;

        // Pandoc: the closing $ is not preceded by a space nor followed by a
        // digit (`I paid $5 for $10` is prose). An invalid closer fails the
        // attempt instead of scanning on: the parser is re-invoked at every
        // later `$`, so `price $5, cost $x$` matches exactly `$x$`.
        const beforeClose = cx.char(end - 1);
        if (beforeClose === SPACE || beforeClose === TAB) return -1;
        const afterClose = cx.char(end + 1);
        if (afterClose >= 48 && afterClose <= 57) return -1; // '0'-'9'

        return cx.addElement(
          cx.elt('InlineMath', pos, end + 1, [
            cx.elt('InlineMathMark', pos, pos + 1),
            cx.elt('InlineMathMark', end, end + 1),
          ]),
        );
      }

      // A newline is hard-wrapped prose: keep scanning, like the tex scanner.
      // A blank line aborts, so a stray `$` can't reach across paragraphs
      // (matters for lazy-continuation shapes; `cx.end` caps the rest).
      if (ch === NEWLINE && blankLineAfter(cx, end)) return -1;
      if (ch === BACKSLASH) end++;
      end++;
    }

    return -1;
  },
};

// ---------------------------------------------------------------------------
//  Lezer InlineParser: paragraph-interior $$…$$ (Pandoc display math)
// ---------------------------------------------------------------------------

/**
 * `$$…$$` that does NOT open a line ("this becomes $$ c_0 $$ so …"): display
 * math mid-paragraph, as Pandoc does. Its own node because every whole-line
 * assumption of the block form is wrong for it. A line-start `$$` never gets
 * here: `displayMathParser` claims it first. Scan rules as `inlineMathParser`.
 */
const inlineDisplayMathParser: InlineParser = {
  name: 'InlineDisplayMath',

  parse(cx: InlineContext, next: number, pos: number): number {
    if (next !== DOLLAR || cx.char(pos + 1) !== DOLLAR) return -1;

    let end = pos + 2;
    while (end < cx.end) {
      const ch = cx.char(end);
      if (ch === DOLLAR && cx.char(end + 1) === DOLLAR) {
        if (cx.slice(pos + 2, end).trim() === '') return -1;
        return cx.addElement(
          cx.elt('InlineDisplayMath', pos, end + 2, [
            cx.elt('InlineDisplayMathMark', pos, pos + 2),
            cx.elt('InlineDisplayMathMark', end, end + 2),
          ]),
        );
      }
      if (ch === NEWLINE && blankLineAfter(cx, end)) return -1;
      if (ch === BACKSLASH) end++;
      end++;
    }
    return -1;
  },
};

// ---------------------------------------------------------------------------
//  Lezer BlockParser: teaches the markdown parser about $$…$$
// ---------------------------------------------------------------------------

/** A closing `$$` that ends its line, optionally followed by a Quarto
 *  attribute list (`$$ {#eq-ols}`). The match index is the `$$`. */
const CLOSE_AT_END = /\$\$\s*(?:\{[^}]*\})?\s*$/;

/**
 * How the text after a line-opening `$$` ends that line:
 *   a number  a single-line block; its closing `$$` starts at that offset.
 *   'prose'   a `$$` that is not such a close (`$$x$$.`), or an empty body:
 *             not a block, so InlineDisplayMath gets the paragraph.
 *   null      no `$$` at all: the first line of a multi-line block.
 */
function singleLineClose(afterOpen: string): number | 'prose' | null {
  const close = CLOSE_AT_END.exec(afterOpen);
  if (close) return afterOpen.slice(0, close.index).trim() === '' ? 'prose' : close.index;
  return afterOpen.includes('$$') ? 'prose' : null;
}

const displayMathParser: BlockParser = {
  name: 'DisplayMath',
  parse(cx: BlockContext, line: Line): boolean {
    if (line.next !== DOLLAR) return false;
    if (line.text.charCodeAt(line.pos + 1) !== DOLLAR) return false;

    const openStart = cx.lineStart + line.pos;
    const afterDollar = line.text.slice(line.pos + 2);

    if (afterDollar.trim() === '') {
      // `$$` on its own line.
      const openEnd = cx.lineStart + line.text.length;

      while (cx.nextLine()) {
        // Close line `$$`, optionally with `{#eq-…}`: the mark covers only the
        // `$$`, the node runs to line end so the widget hides the label. Match
        // after `line.pos`: in a blockquote the text keeps its `> ` prefix, and
        // an anchored match would never close and claim to EOF.
        const closeMatch = /^(\s*)\$\$\s*(?:\{[^}]*\})?\s*$/.exec(line.text.slice(line.pos));
        if (closeMatch) {
          const closeStart = cx.lineStart + line.pos + closeMatch[1].length;
          const closeEnd = cx.lineStart + line.text.length;

          cx.addElement(
            cx.elt('DisplayMath', openStart, closeEnd, [
              cx.elt('DisplayMathMark', openStart, openEnd),
              cx.elt('DisplayMathMark', closeStart, closeStart + 2),
            ]),
          );
          cx.nextLine();
          return true;
        }
      }
      // No closing `$$`: claim to EOF with one open mark, like an unclosed
      // code fence. The lines are consumed and a BlockParser must not consume
      // without claiming (returning false strips all block structure below).
      // It also keeps incremental reparse correct: typing the close lands in
      // this node. `prevLineEnd()` because the failed nextLine() advanced.
      cx.addElement(
        cx.elt('DisplayMath', openStart, cx.prevLineEnd(), [
          cx.elt('DisplayMathMark', openStart, openEnd),
        ]),
      );
      return true;
    }

    // `$$content … content$$`.
    const single = singleLineClose(afterDollar);

    if (single === 'prose') return false;
    if (single !== null) {
      const closeMarkStart = openStart + 2 + single;
      cx.addElement(
        cx.elt('DisplayMath', openStart, cx.lineStart + line.text.length, [
          cx.elt('DisplayMathMark', openStart, openStart + 2),
          cx.elt('DisplayMathMark', closeMarkStart, closeMarkStart + 2),
        ]),
      );
      cx.nextLine();
      return true;
    }

    while (cx.nextLine()) {
      // Pandoc allows no blank line inside: claim what was consumed as an
      // unclosed block and leave the blank line to the normal parse.
      const rest = line.text.slice(line.pos);
      if (rest.trim() === '') break;
      const close = CLOSE_AT_END.exec(rest);
      if (close) {
        const closeMarkStart = cx.lineStart + line.pos + close.index;
        cx.addElement(
          cx.elt('DisplayMath', openStart, cx.lineStart + line.text.length, [
            cx.elt('DisplayMathMark', openStart, openStart + 2),
            cx.elt('DisplayMathMark', closeMarkStart, closeMarkStart + 2),
          ]),
        );
        cx.nextLine();
        return true;
      }
    }
    // Unclosed: claim through the last consumed line, as above.
    cx.addElement(
      cx.elt('DisplayMath', openStart, cx.prevLineEnd(), [
        cx.elt('DisplayMathMark', openStart, openStart + 2),
      ]),
    );
    return true;
  },
  // Ends a paragraph only on a line `parse` would claim, so `$$x$$.` wrapped
  // onto its own line stays in the paragraph.
  endLeaf(_cx: BlockContext, line: Line): boolean {
    if (line.next !== DOLLAR || line.text.charCodeAt(line.pos + 1) !== DOLLAR) return false;
    const afterDollar = line.text.slice(line.pos + 2);
    if (afterDollar.trim() === '') return true;
    return singleLineClose(afterDollar) !== 'prose';
  },
};

/** Defines the math nodes. Pass to `markdown({ extensions: [mathSyntax] })`. */
export const mathSyntax: MarkdownConfig = {
  defineNodes: [
    { name: 'InlineMath', style: tags.monospace },
    { name: 'InlineMathMark', style: tags.processingInstruction },
    { name: 'InlineDisplayMath', style: tags.monospace },
    { name: 'InlineDisplayMathMark', style: tags.processingInstruction },
    { name: 'DisplayMath', style: tags.monospace },
    { name: 'DisplayMathMark', style: tags.processingInstruction },
  ],
  // Order matters: `$$` must be tried before the `$…$` parser sees it.
  parseInline: [inlineDisplayMathParser, inlineMathParser],
  parseBlock: [displayMathParser],
};

// ---------------------------------------------------------------------------
//  Widgets
// ---------------------------------------------------------------------------

class KaTeXInlineWidget extends WidgetType {
  constructor(readonly latex: string) {
    super();
  }

  toDOM(): HTMLElement {
    const span = document.createElement('span');
    const html = katexCache.render(this.latex, false);

    if (html) {
      span.className = 'cm-math-rendered cm-math-inline';
      span.innerHTML = html;
    } else {
      span.className = 'cm-math-error';
      span.textContent = `$${this.latex}$`;
    }

    return span;
  }

  eq(other: KaTeXInlineWidget): boolean {
    return this.latex === other.latex;
  }

  ignoreEvent(): boolean {
    return false;
  }
}

class KaTeXBlockWidget extends WidgetType {
  constructor(
    readonly latex: string,
    // Callout box to continue: see mdSettled.
    readonly callout: CalloutTag | null = null,
    // Quarto number for a `$$ … $$ {#eq-…}` block; null when unlabelled.
    readonly eqNumber: string | null = null,
    // KaTeX counter offset: numbers emitted by all preceding display blocks
    // (see displayMathField).
    readonly eqOffset: number = 0,
    // The Quarto id, a dimmed pill on the left (the number owns the right).
    readonly eqId: string | null = null,
  ) {
    super();
  }

  toDOM(): HTMLElement {
    const div = document.createElement('div');
    div.setAttribute('contenteditable', 'false');
    div.style.setProperty('--chalk-eq-offset', String(this.eqOffset));
    const html = katexCache.render(this.latex, true);
    const cls = [html ? 'cm-math-rendered' : 'cm-math-error', 'cm-math-display'];
    cls.push(...calloutTagClasses(this.callout));
    if (this.eqNumber) cls.push('cm-math-numbered');
    div.className = cls.join(' ');
    if (html) div.innerHTML = html;
    else div.textContent = this.latex;
    if (this.eqNumber) {
      const tag = document.createElement('span');
      tag.className = 'cm-eq-number';
      tag.textContent = `(${this.eqNumber})`;
      div.appendChild(tag);
    }
    if (this.eqId) {
      const pill = document.createElement('span');
      pill.className = 'cm-eq-id cm-md-label-pill';
      pill.textContent = this.eqId;
      div.appendChild(pill);
    }
    return div;
  }

  eq(other: KaTeXBlockWidget): boolean {
    return (
      this.latex === other.latex &&
      sameCalloutTag(this.callout, other.callout) &&
      this.eqNumber === other.eqNumber &&
      this.eqId === other.eqId &&
      this.eqOffset === other.eqOffset
    );
  }

  ignoreEvent(): boolean {
    return false;
  }
}

/**
 * Renders an `InlineDisplayMath` node as an INLINE replace: a mid-line
 * `block: true` replace splits the line into two `.cm-line`s and desyncs the
 * height map. The DOM makes its own row: `<br>` + a full-width inline-block.
 *
 * The `<br>` is a forced break so `text-align: justify` doesn't stretch the
 * prose before it. The row is inline-block, not block, so no anonymous block
 * boxes inherit the hanging-indent `text-indent` and outdent the prose after
 * it in a list item.
 */
class KaTeXInlineDisplayWidget extends WidgetType {
  constructor(
    readonly latex: string,
    readonly eqOffset: number = 0,
  ) {
    super();
  }

  toDOM(): HTMLElement {
    const host = document.createElement('span');
    host.className = 'cm-math-inline-display';
    host.setAttribute('contenteditable', 'false');
    host.appendChild(document.createElement('br'));
    const row = document.createElement('span');
    row.style.setProperty('--chalk-eq-offset', String(this.eqOffset));
    const html = katexCache.render(this.latex, true);
    if (html) {
      row.className = 'cm-math-rendered cm-math-display cm-math-inline-display-row';
      row.innerHTML = html;
    } else {
      row.className = 'cm-math-error cm-math-display cm-math-inline-display-row';
      row.textContent = this.latex;
    }
    host.appendChild(row);
    return host;
  }

  eq(other: KaTeXInlineDisplayWidget): boolean {
    return this.latex === other.latex && this.eqOffset === other.eqOffset;
  }

  ignoreEvent(): boolean {
    return false; // clicks go to mathWidgetMousedown
  }
}

// ---------------------------------------------------------------------------
//  ViewPlugin: single-line InlineMath, viewport only
// ---------------------------------------------------------------------------

function spansLineBreak(state: EditorState, from: number, to: number): boolean {
  return state.doc.lineAt(from).number !== state.doc.lineAt(Math.max(from, to - 1)).number;
}

/** The LaTeX inside `$…$`, blockquote markers stripped (see latexBetweenMarks). */
function inlineLatex(state: EditorState, from: number, to: number): string {
  const raw = state.doc.sliceString(from + 1, to - 1);
  if (!QUOTE_PREFIX.test(state.doc.lineAt(from).text)) return raw;
  return raw
    .split('\n')
    .map((l) => l.replace(QUOTE_PREFIX, ''))
    .join('\n');
}

function buildDecorations(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const { state } = view;
  const cursor = state.selection.main;
  // Conceal everything while a double-click runs on pre-reveal geometry.
  const overridden = concealOverridden(state);
  const tree = syntaxTree(state);

  for (const { from, to } of view.visibleRanges) {
    tree.iterate({
      from,
      to,
      enter(node) {
        if (node.name !== 'InlineMath') return;

        const mathFrom = node.from;
        const mathTo = node.to;

        // A wrapped span goes to `displayMathField`: CM6 throws on a
        // line-break-spanning replace from a ViewPlugin.
        if (spansLineBreak(state, mathFrom, mathTo)) return;

        const cursorInside = !overridden && revealReplacedSource(cursor, mathFrom, mathTo);

        if (cursorInside) {
          builder.add(mathFrom, mathTo, MATH_EDITING);
        } else {
          const latex = state.doc.sliceString(mathFrom + 1, mathTo - 1);
          // Trailing punctuation rides with the widget; `inclusiveStart` and
          // this add order are load-bearing (see punctuation-glue).
          const glueTo = glueEnd(state, mathTo);
          if (glueTo > mathTo) {
            builder.add(mathFrom, glueTo, MATH_GLUE);
          }
          builder.add(
            mathFrom,
            mathTo,
            Decoration.replace({ widget: new KaTeXInlineWidget(latex) }),
          );
        }
      },
    });
  }

  return builder.finish();
}

/** Per editor instance: the reveal gate holds per-editor pointer state. */
function makeMathViewPlugin() {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;
      private readonly gate = createRevealGate();

      constructor(view: EditorView) {
        this.decorations = buildDecorations(view);
      }

      update(update: ViewUpdate) {
        const alsoRebuild =
          update.viewportChanged ||
          syntaxTree(update.state) !== syntaxTree(update.startState);
        if (this.gate.decide(revealSignal(update), alsoRebuild) !== 'rebuild') return;
        this.decorations = buildDecorations(update.view);
      }
    },
    { decorations: (v) => v.decorations },
  );
}

// ---------------------------------------------------------------------------
//  md's half of the shared display-math field: regions and settled render
// ---------------------------------------------------------------------------

/**
 * LaTeX from a DisplayMath node's text. Text not wrapped in `$$ … $$` is
 * returned trimmed, so KaTeX errors instead of losing two real chars per end.
 */
function extractDisplayLatex(text: string): string {
  const trimmed = text.trim();
  if (
    trimmed.length < 4 ||
    !trimmed.startsWith('$$') ||
    !trimmed.endsWith('$$')
  ) {
    return trimmed;
  }
  return trimmed.slice(2, -2).trim();
}

const QUOTE_PREFIX = /^\s{0,3}(?:>\s?)+/;

/**
 * The text strictly between a node's two `$$` marks, so a trailing `{#eq-…}`
 * is excluded. A single-mark (unclosed) node falls back to extractDisplayLatex.
 */
function latexBetweenMarks(
  state: EditorState,
  node: MathNode,
  markName: 'DisplayMathMark' | 'InlineDisplayMathMark' = 'DisplayMathMark',
): string {
  const marks = node.getChildren(markName);
  if (marks.length >= 2) {
    const raw = state.doc.sliceString(marks[0].to, marks[1].from);
    // In a blockquote each line keeps its `> `, which KaTeX paints as a
    // relation. Strip only when the OPENING line is quoted.
    const openLine = state.doc.lineAt(marks[0].from).text;
    if (QUOTE_PREFIX.test(openLine)) {
      return raw
        .split('\n')
        .map((l) => l.replace(QUOTE_PREFIX, ''))
        .join('\n')
        .trim();
    }
    return raw.trim();
  }
  return extractDisplayLatex(state.doc.sliceString(node.from, node.to));
}

/** The `eq-…` slug after a display block's closing `$$`, or null. */
function equationLabel(state: EditorState, node: MathNode): string | null {
  const marks = node.getChildren('DisplayMathMark');
  if (marks.length < 2) return null;
  const m = /\{#(eq-[\w-]+)\}/.exec(state.doc.sliceString(marks[1].to, node.to));
  return m ? m[1] : null;
}

/**
 * md's region for the shared field: `DisplayMath`, `InlineDisplayMath`, and a
 * hard-wrapped `InlineMath` (only a StateField may replace across a line break).
 */
interface MdMathRegion extends DisplayMathRegion {
  /** The `DisplayMath` node, for its `{#eq-…}` label. */
  node?: MathNode;
}

const MATH_EDITING = Decoration.mark({ class: 'cm-math-editing' });
const MATH_GLUE = Decoration.mark({ class: 'cm-math-glue', inclusiveStart: true });

/**
 * Memoized on doc AND tree: the field and the Up/Down keymap ask on nearly
 * every transaction, and a whole-tree walk is too much per arrow key. The doc
 * alone goes stale when a background parse advances the tree; content is
 * sliced from the doc, so the tree alone is not enough either.
 */
const regionCache = new WeakMap<
  Text,
  { tree: ReturnType<typeof syntaxTree>; regions: MdMathRegion[] }
>();

function mdMathRegions(state: EditorState): MdMathRegion[] {
  const tree = syntaxTree(state);
  const hit = regionCache.get(state.doc);
  if (hit && hit.tree === tree) return hit.regions;
  const regions = scanMdMathRegions(state, tree);
  regionCache.set(state.doc, { tree, regions });
  return regions;
}

function scanMdMathRegions(
  state: EditorState,
  tree: ReturnType<typeof syntaxTree>,
): MdMathRegion[] {
  const regions: MdMathRegion[] = [];
  tree.iterate({
    enter(node) {
      // Single-line `$…$` stays with the view plugin (viewport cost only).
      if (node.name === 'InlineMath') {
        if (!spansLineBreak(state, node.from, node.to)) return false;
        regions.push({
          from: node.from,
          to: node.to,
          content: inlineLatex(state, node.from, node.to),
          display: false,
          block: false,
          revealDeco: MATH_EDITING,
        });
        return false;
      }
      // Paragraph-interior `$$…$$`: char-based reveal, preview under the
      // paragraph. Served here because it may span a line break and must join
      // the document-order equation count.
      if (node.name === 'InlineDisplayMath') {
        if (node.node.getChildren('InlineDisplayMathMark').length < 2) return false;
        regions.push({
          from: node.from,
          to: node.to,
          content: latexBetweenMarks(state, node.node, 'InlineDisplayMathMark'),
          display: true,
          block: false,
          previewTo: state.doc.lineAt(node.to).to,
          revealDeco: MATH_EDITING,
        });
        return false;
      }
      if (node.name !== 'DisplayMath') return;
      // Unclosed block: no region, or the widget swallows the rest of the
      // document and the preview renders the prose that follows.
      if (node.node.getChildren('DisplayMathMark').length < 2) return;
      regions.push({
        from: node.from,
        to: node.to,
        content: latexBetweenMarks(state, node.node),
        display: true,
        block: true,
        node: node.node,
      });
    },
  });
  return regions;
}

/**
 * The rendered widget for a region the caret is not in. A block inside a
 * callout is tagged to continue the box (a block widget isn't a `.cm-line`);
 * as the box bottom it absorbs the collapsed fence (`hideTo`), or the fence's
 * hide leaves a phantom row. See calloutBlockAt.
 */
function mdSettled(
  state: EditorState,
  region: MdMathRegion,
  eqOffset: number,
): { widget: WidgetType; hideTo?: number } {
  if (!region.block) {
    return {
      widget: region.display
        ? new KaTeXInlineDisplayWidget(region.content, eqOffset)
        : new KaTeXInlineWidget(region.content),
    };
  }
  const callout = calloutBlockAt(
    state.doc,
    scanCallouts,
    region.from,
    region.to,
    state.selection.main,
  );
  const label = region.node ? equationLabel(state, region.node) : null;
  const eqNumber = label ? crossrefIndex(state.doc).get(label)?.number ?? null : null;
  return {
    widget: new KaTeXBlockWidget(region.content, callout, eqNumber, eqOffset, label),
    hideTo: callout?.hideTo,
  };
}

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

/**
 * Math rendering (inline + display). The parser config, `mathSyntax`, is
 * passed separately to `markdown()`.
 */
export function mathPlugin(): Extension {
  return [
    makeMathViewPlugin(),
    displayMathField<MdMathRegion>({
      regionsOf: mdMathRegions,
      settled: mdSettled,
      preview: {
        cache: katexCache,
        className: 'cm-math-preview',
        scanCallouts,
      },
      widgetSelector: '.cm-math-inline, .cm-math-display',
      blockObeysConcealOverride: true,
      // Rebuild as the background parse advances, so blocks past the first
      // parse window render (like tableField). Don't wait for a complete tree:
      // in a long document it never comes.
      alsoRebuild: (tr) => syntaxTree(tr.state) !== syntaxTree(tr.startState),
    }),
  ];
}

// Up/Down into collapsed display math (displayMathArrows): only closed
// `DisplayMath` blocks are stops.
const mdArrows = displayMathArrows(mdMathRegions);

export const mdMathArrowKeymap: Extension = mdArrows.extension;

// Exported for tests.
export const _testing = {
  mdEnterDisplayMathFromAbove: mdArrows.fromAbove,
  mdEnterDisplayMathFromBelow: mdArrows.fromBelow,
  mdMathRegions,
  // Reached directly so a test sees a throw: CM6 swallows one from a live
  // plugin and disables it.
  buildInlineMathDecorations: buildDecorations,
};

/** True when `pos` is inside a math node; the md `isInMathContext` callback. */
export function isInMathContextMd(state: EditorState, pos: number): boolean {
  const tree = syntaxTree(state);
  const node = tree.resolveInner(pos);
  let n: { name: string; parent: typeof node | null } | null = node;
  while (n) {
    if (n.name === 'InlineMath' || n.name === 'InlineDisplayMath' || n.name === 'DisplayMath') {
      return true;
    }
    n = n.parent;
  }
  return false;
}
