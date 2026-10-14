import {
  Decoration,
  DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
  WidgetType,
} from '@codemirror/view';
import { EditorState, Extension, RangeSetBuilder } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import '../styles/editor.css';
import { liveLinkClickHandler, liveLinkMark } from './live-link';
import { ImageWidget } from './image-widget';
import { glueEnd, glueStart } from './punctuation-glue';
import { concealOverridden } from './pointer-gesture';
import { createRevealGate, revealSignal } from './reveal-gate';
import {
  HIDE,
  revealDelimitedSource,
  revealDelimitedSourceInclusive,
  revealMarked,
  revealReplacedSource,
  SYNTAX_DIM,
} from './reveal';

// ---------------------------------------------------------------------------
//  Widgets
// ---------------------------------------------------------------------------

/**
 * A Quarto id (`{#sec-setup}`) rendered as a dimmed pill. An id is what
 * `@sec-setup` points at, so it stays readable, like the tex `\label{…}` pill
 * (R-T4 in docs/specs/2026-08-23-caret-and-reveal-semantics.md).
 */
class QuartoIdWidget extends WidgetType {
  constructor(readonly id: string) {
    super();
  }

  eq(other: QuartoIdWidget): boolean {
    return other.id === this.id;
  }

  toDOM(): HTMLElement {
    const span = document.createElement('span');
    span.className = 'cm-md-label-pill';
    span.textContent = this.id;
    return span;
  }

  ignoreEvent(): boolean {
    return false; // a click places the caret, which reveals the raw source
  }
}

// ---------------------------------------------------------------------------
//  Build live-preview decorations from the syntax tree
// ---------------------------------------------------------------------------

interface LivePreviewOptions {
  /** Preview (default) hides delimiters and reveals them under the caret.
   *  `false` is Mixed: delimiters stay as dimmed marks and nothing reveals.
   *  Images are replaced whole in both modes. */
  conceal?: boolean;
}

/**
 * The three decorations that conceal an inline construct's delimiters, plus a
 * `cm-live-glue` nowrap mark when punctuation follows the closing one with no
 * space: the replaced delimiter leaves `.cm-widgetBuffer` anchors the browser
 * may wrap after (see punctuation-glue). Mixed replaces nothing, so it creates
 * no anchor and needs no glue.
 */
function emitConcealed(
  state: EditorState,
  emit: (from: number, to: number, dec: Decoration) => void,
  hide: (from: number, to: number, dec?: Decoration) => void,
  conceal: boolean,
  opening: { from: number; to: number },
  closing: { from: number; to: number },
  className: string,
): void {
  if (!conceal) {
    hide(opening.from, opening.to);
    emit(opening.to, closing.from, Decoration.mark({ class: className }));
    hide(closing.from, closing.to);
    return;
  }
  const parts: Array<{ from: number; to: number; dec: Decoration }> = [
    { from: opening.from, to: opening.to, dec: HIDE },
    { from: opening.to, to: closing.from, dec: Decoration.mark({ class: className }) },
    { from: closing.from, to: closing.to, dec: HIDE },
  ];
  const glueTo = glueEnd(state, closing.to);
  if (glueTo > closing.to) {
    parts.push({
      from: glueStart(state, closing.from, opening.from),
      to: glueTo,
      dec: LIVE_GLUE,
    });
  }
  // RangeSetBuilder needs (from, startSide) order, which also decides which
  // mark nests outside which; reading startSide off the decorations gets both.
  parts.sort((a, b) => a.from - b.from || a.dec.startSide - b.dec.startSide);
  for (const part of parts) emit(part.from, part.to, part.dec);
}

const HEADER_MARK = Decoration.mark({ class: 'cm-md-header-mark' });
const LIVE_GLUE = Decoration.mark({ class: 'cm-live-glue', inclusiveStart: true });
const HEADING_MARKS = [1, 2, 3, 4, 5, 6].map((l) => Decoration.mark({ class: `cm-h${l}` }));
const BLOCKQUOTE_MARK = Decoration.mark({ class: 'cm-live-blockquote' });
const QUOTE_MARK = Decoration.mark({ class: 'cm-live-quote-mark' });
const LIST_MARK = Decoration.mark({ class: 'cm-live-list-mark' });

/** Inline constructs rendered by hiding their first and last delimiter mark
 *  and classing what lies between: node name → mark child name and class. */
const MARKED_INLINE = new Map<string, { mark: string; className: string }>([
  ['StrongEmphasis', { mark: 'EmphasisMark', className: 'cm-live-bold' }],
  ['Emphasis', { mark: 'EmphasisMark', className: 'cm-live-italic' }],
  ['Strikethrough', { mark: 'StrikethroughMark', className: 'cm-live-strikethrough' }],
  ['Highlight', { mark: 'HighlightMark', className: 'cm-live-highlight' }],
  ['InlineCode', { mark: 'CodeMark', className: 'cm-live-code' }],
]);

/** Markdown live-preview scope: headings, emphasis, strikethrough,
 * `==highlight==`, code, links, images, blockquotes, lists (math, tables and
 * callouts have their own plugins). Don't expand to footnotes/MDX without a
 * concrete need. Exported for tests, which synthesise the multi-`visibleRanges`
 * view a block widget produces (jsdom never does). */
export function buildLivePreviewDecorations(
  view: EditorView,
  opts: LivePreviewOptions = {},
): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const { state } = view;
  const cursor = state.selection.main;
  const cursorLineNo = state.doc.lineAt(cursor.head).number;
  const tree = syntaxTree(state);

  // A replaced block (display math, callout, table) splits `visibleRanges`, so
  // a node straddling a gap (a blockquote around `$$`) is entered once per
  // piece. Re-emitting it would add a `from` behind its already-added
  // children; RangeSetBuilder throws and CM6 drops the whole plugin. So a node
  // already emitted by an earlier piece is walked for its children only.
  let emittedTo = -1;
  let alreadyEmitted = false;
  const emit = (from: number, to: number, dec: Decoration): void => {
    if (!alreadyEmitted) builder.add(from, to, dec);
  };

  const conceal = opts.conceal ?? true;
  // A double-click forces conceal-everything for its duration
  // (pointer-gesture.ts), so the second click selects what the first saw.
  const overridden = concealOverridden(state);
  /** Replaced by `dec` in Preview, shown dimmed in Mixed. */
  const hide = (from: number, to: number, dec: Decoration = HIDE): void => {
    if (from >= to) return;
    emit(from, to, conceal ? dec : SYNTAX_DIM);
  };
  /** Mixed hides nothing, so it never reveals. Wrap every reveal check except
   *  the image's. */
  const reveal = (revealed: boolean): boolean => conceal && !overridden && revealed;

  for (const { from, to } of view.visibleRanges) {
    tree.iterate({
      from,
      to,
      enter(node) {
        alreadyEmitted = node.from < emittedTo;

        // Math is math-plugin.ts's.
        if (
          node.name === 'InlineMath' ||
          node.name === 'InlineDisplayMath' ||
          node.name === 'DisplayMath'
        ) {
          return false; // don't descend into children
        }

        // Tables are replaced whole by table-field.ts.
        if (node.name === 'Table') {
          return false;
        }

        // ---- Headings ----
        // The `#` marks stay visible by design (VS Code convention).
        const headingMatch = node.name.match(/^ATXHeading(\d)$/);
        if (headingMatch) {
          const level = parseInt(headingMatch[1]);
          emit(node.from, node.to, HEADING_MARKS[level - 1]);
          // The leading `#` run and the space after it get their own class,
          // so a theme can quiet them or hang them in the margin.
          const headerMark = node.node.getChild('HeaderMark');
          if (headerMark && headerMark.from === node.from) {
            const lineTo = state.doc.lineAt(node.from).to;
            const space = /^[ \t]*/.exec(state.doc.sliceString(headerMark.to, lineTo))![0].length;
            emit(headerMark.from, headerMark.to + space, HEADER_MARK);
          }
          // A trailing Quarto attribute (`# Setup {#sec-setup}`) becomes a pill.
          const text = state.doc.sliceString(node.from, node.to);
          const attr = /(\s*)\{#([\w-]+)\}\s*$/.exec(text);
          // Inclusive end: the attribute ends the line, so the position after
          // `}` is the only one past it. The hide is only the `{#…}`, so a
          // selection reveals it only when an end lands inside that.
          const attrFrom = attr ? node.from + attr.index : node.to;
          if (
            attr &&
            !reveal(revealDelimitedSourceInclusive(cursor, node.from, node.to, node.from, attrFrom))
          ) {
            // The hide includes the leading whitespace (R-M3 pins the extent);
            // the pill's CSS margin supplies the gap.
            hide(attrFrom, node.to, Decoration.replace({ widget: new QuartoIdWidget(attr[2]) }));
          }
          return false;
        }

        // ---- Bold, italic, strikethrough, ==highlight==, inline code ----
        const marked = MARKED_INLINE.get(node.name);
        if (marked) {
          // The marks are needed before the reveal check: a selection inside
          // one keeps the source (revealMarked).
          const marks: Array<{ from: number; to: number }> = [];
          let nestedEmphasis = false;
          for (let child = node.node.firstChild; child; child = child.nextSibling) {
            if (child.name === marked.mark) marks.push({ from: child.from, to: child.to });
            else if (child.name === 'Emphasis') nestedEmphasis = true;
          }

          // Caret on the opening delimiter = inside, past the closing = outside.
          if (reveal(revealMarked(cursor, node.from, node.to, marks))) {
            return false;
          }

          if (marks.length >= 2) {
            // `***x***` is a StrongEmphasis wrapping an Emphasis.
            const className =
              node.name === 'StrongEmphasis' && nestedEmphasis
                ? 'cm-live-bold-italic'
                : marked.className;
            emitConcealed(state, emit, hide, conceal, marks[0], marks[marks.length - 1], className);
          }

          return false;
        }

        // ---- Images ----
        if (node.name === 'Image') {
          // A selection inside keeps the source: a widget has no position to
          // hold its end. No `reveal()` wrap: images are replaced in both modes.
          if (revealReplacedSource(cursor, node.from, node.to)) return false;

          // Multi-line stays raw: a ViewPlugin replace spanning a line break
          // throws and takes the whole plugin down.
          if (state.doc.lineAt(node.from).number !== state.doc.lineAt(node.to).number) {
            return false;
          }

          const raw = state.doc.sliceString(node.from, node.to);
          const urlNode = node.node.getChild('URL');
          let src = urlNode ? state.doc.sliceString(urlNode.from, urlNode.to).trim() : '';
          if (!src) {
            const m = /\]\(\s*<?([^)\s>]+)/.exec(raw); // fallback if no URL child
            src = m ? m[1] : '';
          }
          const altMatch = /^!\[([^\]]*)\]/.exec(raw);
          const alt = altMatch ? altMatch[1] : '';

          if (src) {
            emit(node.from, node.to, Decoration.replace({ widget: new ImageWidget(src, alt) }));
          }
          return false;
        }

        // ---- Links ----
        if (node.name === 'Link') {
          const n = node.node;
          const urlNode = n.getChild('URL');
          const urlStr = urlNode ? state.doc.sliceString(urlNode.from, urlNode.to) : '';

          const linkMarks: Array<{ from: number; to: number }> = [];
          let child = n.firstChild;
          while (child) {
            if (child.name === 'LinkMark') linkMarks.push({ from: child.from, to: child.to });
            child = child.nextSibling;
          }

          if (linkMarks.length < 2) return false;
          const openBracket = linkMarks[0]; // [
          const closeBracket = linkMarks[1]; // ]

          // A selection inside a hide keeps the source; one on the link text
          // does not, so a word-select still reads as a link.
          if (
            reveal(
              revealDelimitedSource(cursor, node.from, node.to, openBracket.to, closeBracket.from),
            )
          ) {
            return false;
          }

          hide(openBracket.from, openBracket.to);
          emit(openBracket.to, closeBracket.from, liveLinkMark(urlStr));
          hide(closeBracket.from, node.to);

          return false;
        }

        // ---- Blockquote ----
        if (node.name === 'Blockquote') {
          // No `return false`: children (QuoteMark, inline markup) still need a pass.
          emit(node.from, node.to, BLOCKQUOTE_MARK);
        }

        // ---- QuoteMark (`>`) ----
        if (node.name === 'QuoteMark') {
          const cursorOnLine = state.doc.lineAt(node.from).number === cursorLineNo;
          if (!cursorOnLine) emit(node.from, node.to, QUOTE_MARK);
        }

        // ---- List markers ----
        // Marked, never replaced: structural punctuation stays visible, like
        // the `#`. No return: list item children still need a pass.
        if (node.name === 'ListMark') {
          emit(node.from, node.to, LIST_MARK);
        }

        // ---- Horizontal rule ----
        // Deliberately a no-op: `---` stays raw source. Rendering it collapsed
        // the line into a blank gap.
        if (node.name === 'HorizontalRule') {
          return false;
        }
      },
    });
    emittedTo = to;
  }

  return builder.finish();
}

function makeLivePreviewViewPlugin(opts: LivePreviewOptions) {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;
      /** One gate per instance (reveal-gate.ts). The viewport and background
       *  parse are this plugin's own rebuild reasons, passed as `alsoRebuild`. */
      private readonly gate = createRevealGate();

      constructor(view: EditorView) {
        this.decorations = buildLivePreviewDecorations(view, opts);
      }

      update(update: ViewUpdate) {
        const alsoRebuild =
          update.viewportChanged ||
          syntaxTree(update.state) !== syntaxTree(update.startState);
        if (this.gate.decide(revealSignal(update), alsoRebuild) !== 'rebuild') return;
        this.decorations = buildLivePreviewDecorations(update.view, opts);
      }
    },
    { decorations: (v) => v.decorations },
  );
}

export function livePreviewPlugin(opts: LivePreviewOptions = {}): Extension {
  return [makeLivePreviewViewPlugin(opts), liveLinkClickHandler];
}
