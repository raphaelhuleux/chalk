import { Decoration, EditorView } from '@codemirror/view';
import { openExternal } from '../host-port';

/** The link mark both languages put over a link's visible text; the click
 *  handler below reads its `data-url`. */
export function liveLinkMark(url: string): Decoration {
  return Decoration.mark({ class: 'cm-live-link', attributes: { 'data-url': url } });
}

/** Cmd/Ctrl+click on a `liveLinkMark` opens its URL through the host. */
export const liveLinkClickHandler = EditorView.domEventHandlers({
  click(event: MouseEvent) {
    if (!event.metaKey && !event.ctrlKey) return false;
    const url = (event.target as HTMLElement).closest('.cm-live-link')?.getAttribute('data-url');
    if (!url) return false;
    openExternal(url);
    return true;
  },
});
