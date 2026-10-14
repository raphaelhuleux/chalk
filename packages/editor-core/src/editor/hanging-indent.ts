import {
  Decoration,
  DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
} from '@codemirror/view';
import { EditorState, Extension, Facet, RangeSetBuilder } from '@codemirror/state';

/**
 * Hanging indent: soft-wrapped rows line up under the text of an indented line
 * or list item. A per-line `--chalk-hang` variable (in `ch`, exact for a
 * monospace font) drives `padding-left: H; text-indent: -H`.
 */

/** Indent of a list body line at `depth`, in em, for tex-list-plugin's layout
 *  and tex-math's in-list display math: LaTeX's leftmargini, then a slightly
 *  smaller step per level. */
export function listHangEm(depth: number): number {
  return depth <= 0 ? 0 : 2.5 + 2.2 * (depth - 1);
}

/**
 * Lines another plugin lays out itself (LaTeX lists in Preview, tex-list-plugin;
 * typeset Markdown lists, md-typeset):
 * each provider maps a state to a per-line predicate, and a matching line gets
 * no `--chalk-hang` from here.
 */
export const hangingIndentSkip = Facet.define<(state: EditorState) => (line: number) => boolean>();

/** Columns of leading whitespace (tabs expand to the next stop) and the index
 *  where it ends. */
function leadingWhitespaceCols(text: string, tabSize: number): { cols: number; end: number } {
  let cols = 0;
  let i = 0;
  for (; i < text.length; i++) {
    const c = text[i];
    if (c === ' ') cols += 1;
    else if (c === '\t') cols += tabSize - (cols % tabSize);
    else break;
  }
  return { cols, end: i };
}

// Bullet with optional task box, ordered marker, or `\item`, plus trailing space.
const MARKER = /^(?:[-*+][ \t]+(?:\[[ xX]\][ \t]+)?|\d+[.)][ \t]+|\\item[ \t]+)/;

/** Columns a line's wrapped rows hang at: indentation plus any list marker. */
export function hangColumns(text: string, tabSize = 4): number {
  const { cols, end } = leadingWhitespaceCols(text, tabSize);
  const m = MARKER.exec(text.slice(end));
  // Marker chars are single-column, so length equals width.
  return cols + (m ? m[0].length : 0);
}

const hangingIndentPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = this.build(view);
    }
    update(update: ViewUpdate): void {
      // The skip set changes with the view mode (a compartment swap), not
      // only with the doc.
      if (
        update.docChanged ||
        update.viewportChanged ||
        update.startState.facet(hangingIndentSkip) !== update.state.facet(hangingIndentSkip)
      ) {
        this.decorations = this.build(update.view);
      }
    }
    build(view: EditorView): DecorationSet {
      const { tabSize } = view.state;
      const skips = view.state.facet(hangingIndentSkip).map((f) => f(view.state));
      const builder = new RangeSetBuilder<Decoration>();
      for (const { from, to } of view.visibleRanges) {
        for (let pos = from; pos <= to; ) {
          const line = view.state.doc.lineAt(pos);
          const cols = skips.some((skip) => skip(line.number)) ? 0 : hangColumns(line.text, tabSize);
          if (cols > 0) {
            builder.add(
              line.from,
              line.from,
              Decoration.line({ attributes: { style: `--chalk-hang:${cols}ch` } }),
            );
          }
          pos = line.to + 1;
        }
      }
      return builder.finish();
    }
  },
  { decorations: (v) => v.decorations },
);

/** Soft-wrapped lines keep their indentation / bullet alignment. */
export function hangingIndent(): Extension {
  return [
    hangingIndentPlugin,
    EditorView.theme({
      // 6px is CM6's default `.cm-line` padding. CM6 reads
      // `paddingLeft + min(0, textIndent)` as the left edge, so the `-H`
      // cancels the hang there and click mapping stays aligned.
      '.cm-line': {
        paddingLeft: 'calc(6px + var(--chalk-hang, 0px))',
        textIndent: 'calc(-1 * var(--chalk-hang, 0px))',
      },
      // `text-indent` inherits into every inline-block widget (math, images,
      // pills), which would paint its content `--chalk-hang` left of its box,
      // over the preceding text. Reset it on descendants; the line's own
      // indent is untouched. Pinned in Tests/browser/run.mjs.
      '.cm-line *': {
        textIndent: '0',
      },
    }),
  ];
}
