import { Decoration, DecorationSet, EditorView } from '@codemirror/view';
import { EditorState, Extension, Range, StateField } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import { normalizeFenceInfo } from './code-languages';
import '../styles/code.css';

// Fenced code block band: line decorations, with the language label as an
// absolutely positioned ::before off `data-lang` (no height, no caret surface).
// Fences stay visible, only dimmed: no collapse, no caret-model changes.
//
// A StateField, not a ViewPlugin: the top/bottom padding changes line heights,
// so the whole document must be decorated to keep CM6's height map right.

const fenceMark = Decoration.mark({ class: 'cm-codeblock-fence' });
const bodyLine = Decoration.line({ class: 'cm-codeblock' });
const bottomLine = Decoration.line({ class: 'cm-codeblock cm-codeblock-bottom' });

function topLine(label: string): Decoration {
  const attributes: { [key: string]: string } = {
    class: 'cm-codeblock cm-codeblock-top',
  };
  if (label) attributes['data-lang'] = label;
  return Decoration.line({ attributes });
}

function buildCodeBlockDecorations(state: EditorState): DecorationSet {
  const decorations: Range<Decoration>[] = [];
  const { doc } = state;
  syntaxTree(state).iterate({
    enter(node) {
      if (node.name === 'Paragraph') return false; // inline content only
      if (node.name !== 'FencedCode') return undefined;
      const info = node.node.getChild('CodeInfo');
      // The label shows even for a language that has no highlighter.
      const label = info ? normalizeFenceInfo(doc.sliceString(info.from, info.to)) : '';
      const first = doc.lineAt(node.from).number;
      const last = doc.lineAt(node.to).number;
      for (let n = first; n <= last; n++) {
        const line = doc.line(n);
        const deco =
          n === first ? topLine(label)
          : n === last && last > first ? bottomLine
          : bodyLine;
        decorations.push(deco.range(line.from));
      }
      for (const mark of node.node.getChildren('CodeMark')) {
        if (mark.to > mark.from) decorations.push(fenceMark.range(mark.from, mark.to));
      }
      if (info && info.to > info.from) decorations.push(fenceMark.range(info.from, info.to));
      return false; // fences don't nest
    },
  });
  return Decoration.set(decorations, true);
}

const codeBlockField = StateField.define<DecorationSet>({
  create(state) {
    return buildCodeBlockDecorations(state);
  },
  update(decos, tr) {
    // Also rebuild on background parse progress, so blocks below the first
    // parse window get their band (as in tableField).
    if (tr.docChanged || syntaxTree(tr.state) !== syntaxTree(tr.startState)) {
      return buildCodeBlockDecorations(tr.state);
    }
    return decos;
  },
  provide: (f) => EditorView.decorations.from(f),
});

export function codeBlockPlugin(): Extension {
  return [codeBlockField];
}
