import {
  Decoration,
  DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
} from '@codemirror/view';
import type { Extension, Range, Text } from '@codemirror/state';
import { SYNTAX_DIM } from './reveal';
import { texLines, uncommented } from './tex-lines';
import { mathRegionsOf } from './tex-math-incremental';
import { regionAt } from './display-math-core';
import { memoByDoc } from '../utils/memo-by-doc';

// ---------------------------------------------------------------------------
//  Layout-only commands (`\vspace{…}`, `\medskip`, `\\[2mm]`, `\FloatBarrier`,
//  `\centering`, …) say nothing about the content, so Preview and Mixed dim
//  them instead of showing them at full ink. A mark only: no replace, no
//  reveal, so caret geometry is untouched and the set is selection-independent.
//  Skipped inside comments, verbatim bodies and math (where `\\` is a row end).
// ---------------------------------------------------------------------------

const LAYOUT = new RegExp(
  [
    // A `\\` line break, with optional star and `[length]`. Listed first so a
    // `\\` pair is consumed before its second backslash can start a command.
    String.raw`\\\\\*?(?:\[[^\]\n]*\])?`,
    String.raw`\\[vh]space\*?\s*\{[^{}\n]*\}`,
    String.raw`\\(?:(?:small|med|big)(?:skip|break)|(?:clear|cleardouble|new)page|FloatBarrier|noindent|centering|raggedright|raggedleft|linebreak|pagebreak|nopagebreak|newline|vfill|hfill|par)(?![A-Za-z@])`,
  ].join('|'),
  'g',
);

/** Document ranges of layout-only commands outside comments and verbatim. Math
 *  is filtered later, against the editor's math regions. */
export const scanLayoutCommands = memoByDoc((doc: Text): Array<{ from: number; to: number }> => {
  const found: Array<{ from: number; to: number }> = [];
  for (const { line, verbatim } of texLines(doc)) {
    if (verbatim) continue;
    const text = uncommented(line.text);
    LAYOUT.lastIndex = 0;
    for (let m = LAYOUT.exec(text); m; m = LAYOUT.exec(text)) {
      found.push({ from: line.from + m.index, to: line.from + m.index + m[0].length });
    }
  }
  return found;
});

function build(view: EditorView): DecorationSet {
  const { state } = view;
  const math = mathRegionsOf(state);
  const ranges: Range<Decoration>[] = [];
  for (const r of scanLayoutCommands(state.doc)) {
    if (regionAt(math, r.from)) continue;
    ranges.push(SYNTAX_DIM.range(r.from, r.to));
  }
  return Decoration.set(ranges, true);
}

/** Preview and Mixed alike: the dim is the same in both. */
export function texLayoutDimPlugin(): Extension {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;
      constructor(view: EditorView) {
        this.decorations = build(view);
      }
      update(update: ViewUpdate) {
        if (update.docChanged) this.decorations = build(update.view);
      }
    },
    { decorations: (v) => v.decorations },
  );
}
