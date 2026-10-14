import {
  Decoration,
  DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
} from '@codemirror/view';
import { Extension, RangeSetBuilder } from '@codemirror/state';
import { ImageWidget } from './image-widget';
import { revealReplacedSource } from './reveal';
import { inLineComment } from './tex-lines';

/**
 * Live preview of `\includegraphics[opts]{path}` as an inline image. The path
 * is reported as written: extension guessing and `\graphicspath` are the host
 * resolver's job.
 */

// No part of a match may cross a line break: a ViewPlugin replace spanning
// lines throws, so a line-wrapped command stays raw source.
const INCLUDEGRAPHICS = /\\includegraphics[ \t]*(?:\[([^\]\n]*)\])?[ \t]*\{([^}\n]*)\}/g;

// width=<fraction>\textwidth (or \linewidth/\columnwidth). Absolute lengths
// and `scale=` are ignored: the image renders at natural size.
const WIDTH_OPTION = /(?:^|,)\s*width\s*=\s*([0-9]*\.?[0-9]+)?\s*\\(?:textwidth|linewidth|columnwidth)\s*(?:,|$)/;

interface TexImageMatch {
  from: number;
  to: number;
  path: string;
  /** Percentage of the text measure, from `width=0.5\textwidth`-style options. */
  widthPct: number | undefined;
}

/** Pure scan of `text` for previewable \includegraphics commands. */
export function scanTexImages(text: string): TexImageMatch[] {
  const matches: TexImageMatch[] = [];
  INCLUDEGRAPHICS.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = INCLUDEGRAPHICS.exec(text)) !== null) {
    const path = m[2].trim();
    if (!path) continue;
    let widthPct: number | undefined;
    const w = m[1]?.match(WIDTH_OPTION);
    if (w) widthPct = (w[1] ? parseFloat(w[1]) : 1) * 100;
    matches.push({ from: m.index, to: m.index + m[0].length, path, widthPct });
  }
  return matches;
}

function buildTexImageDecorations(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const { state } = view;
  const cursor = state.selection.main;

  for (const { from, to } of view.visibleRanges) {
    const text = state.doc.sliceString(from, to);
    for (const m of scanTexImages(text)) {
      const start = from + m.from;
      const end = from + m.to;

      if (inLineComment(state.doc.lineAt(start), start)) continue;

      if (revealReplacedSource(cursor, start, end)) continue;

      builder.add(
        start,
        end,
        Decoration.replace({ widget: new ImageWidget(m.path, '', m.widthPct) }),
      );
    }
  }

  return builder.finish();
}

const texImageViewPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;

    constructor(view: EditorView) {
      this.decorations = buildTexImageDecorations(view);
    }

    update(update: ViewUpdate): void {
      if (update.docChanged || update.selectionSet || update.viewportChanged) {
        this.decorations = buildTexImageDecorations(update.view);
      }
    }
  },
  { decorations: (v) => v.decorations },
);

export function texImagePlugin(): Extension {
  return texImageViewPlugin;
}
