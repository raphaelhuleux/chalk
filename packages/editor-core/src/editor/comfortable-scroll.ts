import { EditorView, scrollPastEnd } from '@codemirror/view';
import type { Extension } from '@codemirror/state';

/**
 * Keep the typing line off the bottom edge (always on): `scrollPastEnd` makes
 * room below the last line, and the 25% bottom margin uses it.
 */
export function comfortableBottom(): Extension {
  return [
    scrollPastEnd(),
    EditorView.scrollMargins.of((view) => ({
      bottom: Math.round(view.dom.clientHeight * 0.25),
    })),
  ];
}

/**
 * Treat the host's translucent chrome band (`--chalk-chrome-top`) as occluded,
 * so scroll-into-view doesn't park the caret under it. Read per scroll: the
 * height changes with full screen and zen; unset (VS Code) gives NaN, no margin.
 * Hosts must set it as an INLINE style on `documentElement`: reading it via
 * `getComputedStyle` here forced a style recalc on every keystroke.
 */
export function chromeTopMargin(): Extension {
  return EditorView.scrollMargins.of((view) => {
    const raw = view.dom.ownerDocument.documentElement.style.getPropertyValue('--chalk-chrome-top');
    const top = Number.parseFloat(raw);
    return Number.isFinite(top) && top > 0 ? { top } : null;
  });
}
