import { EditorView, ViewPlugin } from '@codemirror/view';
import type { Extension } from '@codemirror/state';

/**
 * Mac Catalyst WebKit inserts a committed dead key twice: on AZERTY, `a` `^` `2`
 * yields insertText `^` then `^2` (doc `a^^2`). A composable key (`^` `e` gives
 * `ê`) inserts once, so the rule keys on the repeated prefix: the second insert
 * after a compositionend, before any keydown, that starts with the committed
 * text is cancelled and re-dispatched without it. Only the native host enables
 * it; VS Code (Chromium) must not run it.
 */
export function deadKeyCommitDedupe(): Extension {
  // WebKit's compositionend for a dead key carries no data; use the last update.
  let pending = '';
  // What the composition just committed; '' when no commit window is open.
  let composed = '';
  let commitSeen = false;

  const reset = (): void => {
    composed = '';
    commitSeen = false;
  };

  // A key press closes the window. A raw DOM listener, because CM6 drops key
  // events within 100ms of a compositionend on Safari, exactly this window.
  const keyReset = ViewPlugin.define((view) => {
    view.contentDOM.addEventListener('keydown', reset, true);
    return {
      destroy: () => view.contentDOM.removeEventListener('keydown', reset, true),
    };
  });

  const events = EditorView.domEventHandlers({
    compositionupdate(event) {
      pending = event.data ?? '';
      return false;
    },
    compositionend(event) {
      composed = event.data || pending;
      commitSeen = false;
      pending = '';
      return false;
    },
    beforeinput(event: InputEvent, view) {
      if (!composed) return false;
      const data = event.data ?? '';
      if (event.inputType !== 'insertText') {
        reset();
        return false;
      }
      if (!commitSeen) {
        // The commit itself: let it through and wait for the repeat.
        if (data === composed) {
          commitSeen = true;
          return false;
        }
        reset();
        return false;
      }
      if (data.length > composed.length && data.startsWith(composed)) {
        const rest = data.slice(composed.length);
        reset();
        // Dispatch after CM6's already-queued MutationObserver microtask reads
        // the commit's insert; dispatching now would render over it and lose
        // the committed `^` instead of the duplicate.
        queueMicrotask(() => {
          view.dispatch({
            ...view.state.replaceSelection(rest),
            userEvent: 'input.type',
          });
        });
        return true;
      }
      reset();
      return false;
    },
  });

  return [keyReset, events];
}
