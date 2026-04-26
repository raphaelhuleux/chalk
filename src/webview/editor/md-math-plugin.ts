import {
  Decoration,
  DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
  WidgetType,
} from '@codemirror/view';
import { EditorState, Extension, RangeSetBuilder, StateField, StateEffect } from '@codemirror/state';
import { syntaxTree, syntaxTreeAvailable } from '@codemirror/language';
import type { MarkdownConfig, InlineParser, InlineContext, BlockParser, BlockContext, Line } from '@lezer/markdown';
import { tags } from '@lezer/highlight';
import { KaTeXCache } from '../utils/katex-cache';
import '../styles/math.css';

// ---------------------------------------------------------------------------
//  Shared KaTeX cache instance
// ---------------------------------------------------------------------------

const katexCache = new KaTeXCache();

// ---------------------------------------------------------------------------
//  Lezer InlineParser: teaches the markdown parser about $…$
// ---------------------------------------------------------------------------

const DOLLAR = 36;   // '$'.charCodeAt(0)
const BACKSLASH = 92; // '\'.charCodeAt(0)
const NEWLINE = 10;   // '\n'.charCodeAt(0)

const inlineMathParser: InlineParser = {
  name: 'InlineMath',

  parse(cx: InlineContext, next: number, pos: number): number {
    if (next !== DOLLAR) return -1;

    // Don't match $$ (display math — handled in a future phase)
    if (cx.char(pos + 1) === DOLLAR) return -1;

    // Don't match if this is the second $ of a $$ pair
    if (pos > cx.offset && cx.char(pos - 1) === DOLLAR) return -1;

    // Scan for closing $ (must be on the same line, not $$)
    let end = pos + 1;
    while (end < cx.end) {
      const ch = cx.char(end);

      if (ch === DOLLAR) {
        // Abort if we encounter $$ inside the span (display math)
        if (end + 1 < cx.end && cx.char(end + 1) === DOLLAR) {
          return -1;
        }

        // Must have at least one character between the $ delimiters
        if (end === pos + 1) return -1;

        return cx.addElement(
          cx.elt('InlineMath', pos, end + 1, [
            cx.elt('InlineMathMark', pos, pos + 1),
            cx.elt('InlineMathMark', end, end + 1),
          ]),
        );
      }

      if (ch === NEWLINE) return -1; // inline math can't span lines
      if (ch === BACKSLASH) end++;   // skip escaped character
      end++;
    }

    return -1; // no closing delimiter found
  },
};

// ---------------------------------------------------------------------------
//  Lezer BlockParser: teaches the markdown parser about $$…$$
// ---------------------------------------------------------------------------

const displayMathParser: BlockParser = {
  name: 'DisplayMath',
  parse(cx: BlockContext, line: Line): boolean {
    // Must start with $$
    if (line.next !== DOLLAR) return false;
    if (line.text.charCodeAt(line.pos + 1) !== DOLLAR) return false;

    const openStart = cx.lineStart + line.pos;
    const afterDollar = line.text.slice(line.pos + 2);

    if (afterDollar.trim() === '') {
      // ── Traditional form: $$ on its own line ──
      const openEnd = cx.lineStart + line.text.length;

      while (cx.nextLine()) {
        if (line.text.trim() === '$$') {
          const closeStart = cx.lineStart + line.pos;
          const closeEnd = cx.lineStart + line.text.length;

          cx.addElement(
            cx.elt('DisplayMath', openStart, closeEnd, [
              cx.elt('DisplayMathMark', openStart, openEnd),
              cx.elt('DisplayMathMark', closeStart, closeEnd),
            ]),
          );
          cx.nextLine();
          return true;
        }
      }
      return false;
    }

    // ── Inline-style: $$content … content$$ ──
    const trimmedLine = line.text.trimEnd();

    // Single-line: $$content$$
    if (trimmedLine.endsWith('$$') && trimmedLine.length > line.pos + 4) {
      const inner = trimmedLine.slice(line.pos + 2, -2);
      if (inner.trim() === '') return false;

      const lineEnd = cx.lineStart + line.text.length;
      const closeMarkStart = cx.lineStart + trimmedLine.length - 2;
      cx.addElement(
        cx.elt('DisplayMath', openStart, lineEnd, [
          cx.elt('DisplayMathMark', openStart, openStart + 2),
          cx.elt('DisplayMathMark', closeMarkStart, closeMarkStart + 2),
        ]),
      );
      cx.nextLine();
      return true;
    }

    // Multi-line: $$content...\n...\ncontent$$
    while (cx.nextLine()) {
      const trimmed = line.text.trimEnd();
      if (trimmed.endsWith('$$')) {
        const lineEnd = cx.lineStart + line.text.length;
        const closeMarkStart = cx.lineStart + trimmed.length - 2;
        cx.addElement(
          cx.elt('DisplayMath', openStart, lineEnd, [
            cx.elt('DisplayMathMark', openStart, openStart + 2),
            cx.elt('DisplayMathMark', closeMarkStart, closeMarkStart + 2),
          ]),
        );
        cx.nextLine();
        return true;
      }
    }
    return false;
  },
  endLeaf(_cx: BlockContext, line: Line): boolean {
    return line.next === DOLLAR && line.text.charCodeAt(line.pos + 1) === DOLLAR;
  },
};

/**
 * MarkdownConfig that defines InlineMath and DisplayMath nodes.
 * Pass this to `markdown({ extensions: [mathSyntax] })`.
 */
export const mathSyntax: MarkdownConfig = {
  defineNodes: [
    { name: 'InlineMath', style: tags.monospace },
    { name: 'InlineMathMark', style: tags.processingInstruction },
    { name: 'DisplayMath', style: tags.monospace },
    { name: 'DisplayMathMark', style: tags.processingInstruction },
  ],
  parseInline: [inlineMathParser],
  parseBlock: [displayMathParser],
};

// ---------------------------------------------------------------------------
//  KaTeX inline widget
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
      // Parse error — show raw source with error styling
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

// ---------------------------------------------------------------------------
//  KaTeX display-math widget (rendered mode — replaces entire block)
// ---------------------------------------------------------------------------

class KaTeXBlockWidget extends WidgetType {
  constructor(readonly latex: string) {
    super();
  }

  toDOM(): HTMLElement {
    const div = document.createElement('div');
    div.setAttribute('contenteditable', 'false');
    const html = katexCache.render(this.latex, true);
    if (html) {
      div.className = 'cm-math-rendered cm-math-display';
      div.innerHTML = html;
    } else {
      div.className = 'cm-math-error cm-math-display';
      div.textContent = this.latex;
    }
    return div;
  }

  eq(other: KaTeXBlockWidget): boolean {
    return this.latex === other.latex;
  }

  ignoreEvent(): boolean {
    return false; // Allow clicks to enter edit mode
  }
}

// ---------------------------------------------------------------------------
//  KaTeX display-math preview widget (edit mode — shown below block)
// ---------------------------------------------------------------------------

class KaTeXPreviewWidget extends WidgetType {
  constructor(
    readonly latex: string,
    readonly lastValidHtml: string,
  ) {
    super();
  }

  toDOM(): HTMLElement {
    const div = document.createElement('div');
    div.className = 'cm-math-preview';
    div.setAttribute('contenteditable', 'false');
    const html = katexCache.render(this.latex, true);
    div.innerHTML = html ?? this.lastValidHtml;
    return div;
  }

  updateDOM(dom: HTMLElement): boolean {
    const html = katexCache.render(this.latex, true);
    dom.innerHTML = html ?? this.lastValidHtml;
    return true;
  }

  eq(other: KaTeXPreviewWidget): boolean {
    return this.latex === other.latex && this.lastValidHtml === other.lastValidHtml;
  }

  ignoreEvent(): boolean {
    return true;
  }
}

// ---------------------------------------------------------------------------
//  ViewPlugin: builds decorations from InlineMath syntax nodes
// ---------------------------------------------------------------------------

function buildDecorations(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const { state } = view;
  const cursor = state.selection.main;
  const tree = syntaxTree(state);

  for (const { from, to } of view.visibleRanges) {
    tree.iterate({
      from,
      to,
      enter(node) {
        if (node.name !== 'InlineMath') return;

        const mathFrom = node.from;
        const mathTo = node.to;

        // Cursor is "inside" when the caret sits anywhere within [from, to)
        const cursorInside =
          cursor.head >= mathFrom && cursor.head < mathTo;

        if (cursorInside) {
          // Edit mode — show raw $…$ with subtle styling
          builder.add(
            mathFrom,
            mathTo,
            Decoration.mark({ class: 'cm-math-editing' }),
          );
        } else {
          // Render mode — replace with KaTeX widget
          const latex = state.doc.sliceString(mathFrom + 1, mathTo - 1);
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

export const mathViewPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;

    constructor(view: EditorView) {
      this.decorations = buildDecorations(view);
    }

    update(update: ViewUpdate) {
      if (
        update.docChanged ||
        update.selectionSet ||
        update.viewportChanged ||
        syntaxTree(update.state) !== syntaxTree(update.startState)
      ) {
        this.decorations = buildDecorations(update.view);
      }
    }
  },
  { decorations: (v) => v.decorations },
);

// ---------------------------------------------------------------------------
//  StateField: builds decorations for DisplayMath nodes
// ---------------------------------------------------------------------------

const MAX_LAST_VALID = 100;
const lastValidRenders = new Map<string, string>();
const requestPreviewUpdate = StateEffect.define<null>();

/**
 * Extract LaTeX content from a DisplayMath node's full text.
 * Works for all forms: traditional ($$\n...\n$$), single-line ($$...$$),
 * and multi-line inline ($$...\n...\n...$$).
 *
 * Defensive: if the trimmed input isn't actually wrapped in `$$ … $$`
 * (would indicate the parser shape drifted), returns the trimmed text
 * as-is so KaTeX surfaces a parse error rather than us silently
 * shaving two real content chars off each end.
 */
export function extractDisplayLatex(text: string): string {
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

function buildDisplayMathDecorations(state: EditorState): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const cursor = state.selection.main;
  const tree = syntaxTree(state);
  const decorations: Array<{ from: number; to: number; deco: Decoration }> = [];

  tree.iterate({
    enter(node) {
      if (node.name !== 'DisplayMath') return;
      const blockFrom = node.from;
      const blockTo = node.to;

      // Extract inner LaTeX (strip $$ delimiter lines)
      const fullText = state.doc.sliceString(blockFrom, blockTo);
      const latex = extractDisplayLatex(fullText);

      // Line-based for display math: source stays visible whenever the
      // cursor's line touches the block (including the delimiter lines),
      // so selecting the whole `$$…$$` block doesn't collapse under the
      // cursor mid-drag. Inline math (above) keeps its char-based check.
      const startLine = state.doc.lineAt(blockFrom).number;
      const endLine = state.doc.lineAt(Math.max(blockFrom, blockTo - 1)).number;
      const cursorLine = state.doc.lineAt(cursor.head).number;
      const cursorInside = cursorLine >= startLine && cursorLine <= endLine;

      if (cursorInside) {
        // EDIT MODE: preview widget after closing $$
        const html = katexCache.render(latex, true);
        if (html) {
          lastValidRenders.delete(latex); // Move to end (LRU)
          lastValidRenders.set(latex, html);
          if (lastValidRenders.size > MAX_LAST_VALID) {
            const oldest = lastValidRenders.keys().next().value!;
            lastValidRenders.delete(oldest);
          }
        }
        const lastValid = html ?? lastValidRenders.get(latex) ?? '';

        decorations.push({
          from: blockTo,
          to: blockTo,
          deco: Decoration.widget({
            widget: new KaTeXPreviewWidget(latex, lastValid),
            block: true,
            side: 1,
          }),
        });
      } else {
        // RENDER MODE: replace entire block
        decorations.push({
          from: blockFrom,
          to: blockTo,
          deco: Decoration.replace({
            widget: new KaTeXBlockWidget(latex),
            block: true,
          }),
        });
      }
    },
  });

  decorations.sort((a, b) => a.from - b.from || a.to - b.to);
  for (const { from, to, deco } of decorations) {
    builder.add(from, to, deco);
  }
  return builder.finish();
}

export const displayMathField = StateField.define<DecorationSet>({
  create(state) {
    return buildDisplayMathDecorations(state);
  },
  update(decos, tr) {
    if (!tr.docChanged && !tr.selection && !tr.effects.some(e => e.is(requestPreviewUpdate))) {
      return decos;
    }
    if (!syntaxTreeAvailable(tr.state)) {
      return decos.map(tr.changes);
    }
    return buildDisplayMathDecorations(tr.state);
  },
  provide: (f) => [
    EditorView.decorations.from(f),
    EditorView.atomicRanges.of((view) => view.state.field(f)),
  ],
});

// ---------------------------------------------------------------------------
//  Debounced preview updates for display math editing
// ---------------------------------------------------------------------------

const displayMathDebouncer = ViewPlugin.fromClass(
  class {
    private timer: ReturnType<typeof setTimeout> | null = null;

    update(update: ViewUpdate) {
      if (!update.docChanged) return;
      const cursor = update.state.selection.main;
      const nodeAt = syntaxTree(update.state).resolveInner(cursor.from);
      let insideDisplayMath = false;
      let n = nodeAt as { name: string; parent: typeof nodeAt | null } | null;
      while (n) {
        if (n.name === 'DisplayMath') { insideDisplayMath = true; break; }
        n = n.parent;
      }

      if (insideDisplayMath) {
        if (this.timer) clearTimeout(this.timer);
        this.timer = setTimeout(() => {
          update.view.dispatch({ effects: requestPreviewUpdate.of(null) });
        }, 150);
      }
    }

    destroy() {
      if (this.timer) clearTimeout(this.timer);
    }
  },
);

// ---------------------------------------------------------------------------
//  Theme: force KaTeX text to inherit the editor's foreground color.
//  Uses CM6's baseTheme (StyleModule) so the rules are always injected
//  regardless of how external CSS files are loaded.
// ---------------------------------------------------------------------------

const mathBaseTheme = EditorView.baseTheme({
  '.cm-math-rendered': {
    color: 'inherit',
  },
  // Target the .katex container and ALL descendants — uses the
  // `.cm-editor` prefix that baseTheme adds automatically for specificity.
  '.cm-math-rendered .katex': {
    color: 'inherit',
  },
});

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

/**
 * Walk the full syntax tree and pre-render all math into the KaTeX cache.
 * Call via requestIdleCallback after document load for instant scroll.
 * Returns the number of math expressions pre-rendered.
 */
export function preRenderAllMath(state: EditorState): number {
  const tree = syntaxTree(state);
  let count = 0;

  tree.iterate({
    enter(node) {
      if (node.name === 'InlineMath') {
        const latex = state.doc.sliceString(node.from + 1, node.to - 1);
        katexCache.render(latex, false);
        count++;
      } else if (node.name === 'DisplayMath') {
        const fullText = state.doc.sliceString(node.from, node.to);
        const latex = extractDisplayLatex(fullText);
        katexCache.render(latex, true);
        count++;
      }
    },
  });

  return count;
}

/**
 * Returns the CM6 extension array for math rendering (inline + display).
 * Does NOT include the markdown parser config — that must be passed
 * separately to `markdown({ extensions: [mathSyntax] })`.
 */
export function mathPlugin(): Extension {
  return [mathViewPlugin, displayMathField, displayMathDebouncer, mathBaseTheme];
}

/**
 * Returns true when `pos` lies inside an `InlineMath` or `DisplayMath`
 * node in the markdown syntax tree. Hsnips passes this as the
 * `isInMathContext` callback for the markdown editor.
 */
export function isInMathContextMd(state: EditorState, pos: number): boolean {
  const tree = syntaxTree(state);
  const node = tree.resolveInner(pos);
  let n: { name: string; parent: typeof node | null } | null = node;
  while (n) {
    if (n.name === 'InlineMath' || n.name === 'DisplayMath') return true;
    n = n.parent;
  }
  return false;
}
