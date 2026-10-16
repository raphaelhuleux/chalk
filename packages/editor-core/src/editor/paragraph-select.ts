import { EditorSelection, Extension } from '@codemirror/state';
import { EditorView, MouseSelectionStyle } from '@codemirror/view';

// Triple-click selects the paragraph (the logical line) without its line break,
// as prose editors do: pasting it never adds a blank line. CM6's default takes
// the break too, the code-editor convention (Tests/fixtures/mouse/23). A drag
// that continues the triple-click extends by whole paragraphs, still stopping
// at the last one's end.

export function paragraphSelectionStyle(view: EditorView, start: MouseEvent): MouseSelectionStyle | null {
  if (start.detail !== 3 || start.button !== 0) return null;
  let anchor = view.posAtCoords({ x: start.clientX, y: start.clientY }, false);
  return {
    get(event) {
      const doc = view.state.doc;
      const first = doc.lineAt(anchor);
      const head = doc.lineAt(view.posAtCoords({ x: event.clientX, y: event.clientY }, false));
      // Anchored on the side away from the pointer, so Shift+arrow keeps extending from it.
      return head.from < first.from
        ? EditorSelection.single(first.to, head.from)
        : EditorSelection.single(first.from, head.to);
    },
    update(update) {
      if (update.docChanged) anchor = update.changes.mapPos(anchor);
      return false;
    },
  };
}

export function paragraphSelectExtension(): Extension {
  return EditorView.mouseSelectionStyle.of(paragraphSelectionStyle);
}
