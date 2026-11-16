import { foldedRanges } from '@codemirror/language';
import type { Extension } from '@codemirror/state';
import { EditorView, RectangleMarker, layer, type LayerMarker } from '@codemirror/view';
import { foldOnLine } from './md-fold';
import { ancestorsAt, outlineNodeAt, type OutlineNode } from './md-outline-tree';

/**
 * Indentation guides for nested Markdown lists: a thin vertical line from
 * under a parent's marker to the last row of its subtree. Painted in a
 * `layer()` (the AI-marks pattern), never as decorations: nothing is hidden or
 * added to the text flow, so no caret stop, no row height change, and the
 * reveal matrix never sees it. The x comes from the marker's own glyph box, so
 * the guide follows the default, typeset and mixed list styles alike; a parent
 * whose marker is outside CM6's rendered viewport has no box and draws none.
 */

function guideMarkers(view: EditorView): LayerMarker[] {
  const { state } = view;
  const { doc } = state;
  const first = doc.lineAt(view.viewport.from).number;
  const last = doc.lineAt(view.viewport.to).number;
  // Screen to layer coordinates, as the AI-marks layer does.
  const box = view.scrollDOM.getBoundingClientRect();
  const ox = box.left - view.scrollDOM.scrollLeft * view.scaleX;
  const oy = box.top - view.scrollDOM.scrollTop * view.scaleY;
  // Parents above the viewport, then every item inside it.
  const items: OutlineNode[] = ancestorsAt(state, first).filter((n) => n.kind === 'item' && n.line < first);
  for (let n = first; n <= last; n++) {
    const node = outlineNodeAt(state, n);
    if (node?.kind === 'item') items.push(node);
  }
  const out: LayerMarker[] = [];
  for (const node of items) {
    if (node.end <= node.line || foldOnLine(state, node.line)) continue;
    const line = doc.line(node.line);
    const mark = view.coordsForChar(line.from + node.item!.indent.length);
    if (!mark) continue;
    const top = mark.bottom;
    const bottom = view.documentTop + view.lineBlockAt(doc.line(node.end).from).bottom;
    if (bottom <= top) continue;
    out.push(
      new RectangleMarker(
        'cm-md-guide',
        ((mark.left + mark.right) / 2 - ox) / view.scaleX,
        (top - oy) / view.scaleY,
        null,
        (bottom - top) / view.scaleY,
      ),
    );
  }
  return out;
}

const guideTheme = EditorView.baseTheme({
  '.cm-md-guides .cm-md-guide': {
    width: '1px',
    background: 'currentColor',
    opacity: 0.14,
  },
});

export function mdGuidesExtension(): Extension {
  return [
    layer({
      above: false,
      class: 'cm-md-guides',
      markers: guideMarkers,
      update: (u) =>
        u.docChanged ||
        u.viewportChanged ||
        u.geometryChanged ||
        foldedRanges(u.startState) !== foldedRanges(u.state),
    }),
    guideTheme,
  ];
}
