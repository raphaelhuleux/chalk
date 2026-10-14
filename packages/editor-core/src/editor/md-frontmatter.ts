import { Decoration, DecorationSet, EditorView } from '@codemirror/view';
import { EditorState, Extension, StateField, Text } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import type { MarkdownConfig, BlockParser, BlockContext, Line } from '@lezer/markdown';
import '../styles/editor.css';

// YAML frontmatter: a leading `---` … `---` block claimed as one `Frontmatter`
// node. Without it Lezer reads the closing `---` as a Setext underline and the
// preamble renders as an H2. The node is also the range to dim
// (`.cm-frontmatter-dim`, separate from the typewriter/focus `.cm-dim`).

const FENCE = /^(---|\.\.\.)\s*$/;

/**
 * The 1-based line closing a leading frontmatter block, or 0 if none or
 * unterminated. Scans the bare `Text`, for consumers without a syntax tree.
 */
export function frontmatterCloseLine(doc: Text): number {
  if (doc.lines < 2 || doc.line(1).text.trim() !== '---') return 0;
  for (let n = 2; n <= doc.lines; n++) {
    if (FENCE.test(doc.line(n).text)) return n;
  }
  return 0;
}

const frontmatterParser: BlockParser = {
  name: 'Frontmatter',
  parse(cx: BlockContext, line: Line): boolean {
    if (cx.lineStart !== 0) return false;
    if (line.text.trim() !== '---') return false;

    const openStart = cx.lineStart;
    const openEnd = cx.lineStart + line.text.length;

    while (cx.nextLine()) {
      if (FENCE.test(line.text)) {
        const closeStart = cx.lineStart;
        const closeEnd = cx.lineStart + line.text.length;
        cx.addElement(
          cx.elt('Frontmatter', openStart, closeEnd, [
            cx.elt('FrontmatterMark', openStart, openEnd),
            cx.elt('FrontmatterMark', closeStart, closeEnd),
          ]),
        );
        cx.nextLine();
        return true;
      }
    }

    // Unterminated: claim to EOF with one mark (like display math), so typing
    // the closing `---` lands inside this node and the opener is reparsed.
    cx.addElement(
      cx.elt('Frontmatter', openStart, cx.prevLineEnd(), [
        cx.elt('FrontmatterMark', openStart, openEnd),
      ]),
    );
    return true;
  },
};

/** MarkdownConfig adding the `Frontmatter` node. Register FIRST in the
 *  `markdown({ extensions: […] })` list so it claims the top of the document. */
export const frontmatterSyntax: MarkdownConfig = {
  defineNodes: [{ name: 'Frontmatter', block: true }, { name: 'FrontmatterMark' }],
  parseBlock: [{ ...frontmatterParser, before: 'HorizontalRule' }],
};

const dimMark = Decoration.mark({ class: 'cm-frontmatter-dim' });

function buildFrontmatterDecorations(state: EditorState): DecorationSet {
  const tree = syntaxTree(state);
  const node = tree.topNode.getChild('Frontmatter');
  if (!node || node.to <= node.from) return Decoration.none;
  return Decoration.set([dimMark.range(node.from, node.to)]);
}

/** Always-on dim, not gated by any editing mode. */
const frontmatterDimField = StateField.define<DecorationSet>({
  create(state) {
    return buildFrontmatterDecorations(state);
  },
  update(decos, tr) {
    if (!tr.docChanged) return decos.map(tr.changes);
    return buildFrontmatterDecorations(tr.state);
  },
  provide: (f) => EditorView.decorations.from(f),
});

export function frontmatterDimExtension(): Extension {
  return [frontmatterDimField];
}
