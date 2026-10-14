import {
  Decoration,
  DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
} from '@codemirror/view';
import { EditorState, Extension, RangeSetBuilder, StateField } from '@codemirror/state';
import { mathRegionsOf } from './tex-math-incremental';
import {
  fullStyleScan,
  rescanStyleRegions,
  type StyleScan,
  type TexStyleRegion,
} from './tex-style-incremental';
import '../styles/editor.css';

const CSS_CLASS: Record<TexStyleRegion['kind'], string> = {
  h1: 'cm-h1',
  h2: 'cm-h2',
  h3: 'cm-h3',
  strong: 'cm-tex-strong',
  em: 'cm-tex-em',
  tt: 'cm-tex-tt',
  underline: 'cm-tex-underline',
  sc: 'cm-tex-sc',
  runin: 'cm-tex-runin',
  frametitle: 'cm-tex-frametitle',
  framesubtitle: 'cm-tex-framesubtitle',
  ref: 'cm-tex-ref-arg',
  cite: 'cm-tex-ref-arg',
  label: 'cm-tex-label-arg',
  footnote: 'cm-tex-footnote-text',
  caption: 'cm-tex-caption',
  href: 'cm-live-link',
  url: 'cm-live-link',
};

/**
 * Style regions, rescanned incrementally (tex-style-incremental.ts). Must be
 * registered AFTER `mathRegionsField` in setup.ts, so the math regions it reads
 * from `tr.state` are already the new ones.
 */
export const texStyleRegionsField = StateField.define<StyleScan>({
  create(state) {
    return fullStyleScan(state.doc, mathRegionsOf(state));
  },
  update(scan, tr) {
    if (!tr.docChanged) return scan;
    return rescanStyleRegions(
      tr.startState.doc,
      tr.newDoc,
      tr.changes,
      scan,
      mathRegionsOf(tr.startState),
      mathRegionsOf(tr.state),
    );
  },
});

/** The document's style regions, sorted by (from, to). Shared: treat the
 *  array as immutable. */
export function styleRegionsFor(state: EditorState): TexStyleRegion[] {
  return state.field(texStyleRegionsField).regions;
}

const MARK = Object.fromEntries(
  Object.entries(CSS_CLASS).map(([kind, cls]) => [kind, Decoration.mark({ class: cls })]),
) as Record<TexStyleRegion['kind'], Decoration>;

function buildDecorations(view: EditorView): DecorationSet {
  const regions = styleRegionsFor(view.state);

  const builder = new RangeSetBuilder<Decoration>();
  for (const r of regions) {
    if (r.from === r.to) continue; // empty argument, nothing to mark
    builder.add(r.from, r.to, MARK[r.kind]);
  }
  return builder.finish();
}

/**
 * Live styling of LaTeX sectioning and inline text commands. Mark-only over the
 * argument (the `\command{…}` source stays visible), so it layers over the stex
 * highlighting and never collides with the math widgets. Reads
 * `texStyleRegionsField`; texConcealPlugin hides the syntax in preview.
 */
export function texDecorationsPlugin(): Extension {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;

      constructor(view: EditorView) {
        this.decorations = buildDecorations(view);
      }

      update(update: ViewUpdate) {
        // Doc changes only: the marks cover the whole doc, so scrolling and
        // selection changes leave the set valid.
        if (update.docChanged) {
          this.decorations = buildDecorations(update.view);
        }
      }
    },
    { decorations: (v) => v.decorations },
  );
}
