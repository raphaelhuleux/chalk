import { EditorView, ViewPlugin, ViewUpdate } from '@codemirror/view';
import { EditorState, Extension, StateEffect, StateField } from '@codemirror/state';

// Pointer-gesture tracking for reveal-on-caret plugins. Revealing the instant
// a mousedown places the caret reflows text under the pressed pointer, and
// CM6's MouseSelection re-reads coordinates on every 1px move, so a click
// becomes an oscillating drag-select. Two rules:
//
//  1. Freeze while pressed: "select.pointer" transactions don't rebuild reveal
//     decorations; `gestureSettled` at button release does.
//  2. Double-click undo: the release-reveal reflows text between the clicks, so
//     a detail>=2 mousedown soon after one sets `concealOverride` synchronously,
//     before CM6 reads the click coordinates, restoring the pre-reveal geometry
//     for the word select. Clicks that open a widget skip this.
//
// Registered in both language branches of setup.ts, before the consumers, which
// read it through reveal-gate.ts and concealOverridden().

// Generous (macOS double-clicks can exceed 500ms); a stale override costs only
// one conceal flash.
const DOUBLE_CLICK_UNDO_MS = 600;

// Widgets whose own mousedown handler opens them; never arm the undo.
const WIDGET_OPEN_SELECTOR = [
  '.cm-tex-ref-pill',
  '.cm-tex-label-pill',
  '.cm-tex-footnote-mark',
  '.cm-tex-math-inline',
  '.cm-tex-math-display',
  '.cm-math-inline',
  '.cm-math-display',
].join(', ');

// Gesture over: re-evaluate reveals. A pure-effect transaction sets neither
// docChanged nor selectionSet, so consumers must check effects explicitly.
const gestureSettled = StateEffect.define<null>();

// Conceal everything while a double-click runs against pre-reveal geometry.
const setConcealOverride = StateEffect.define<boolean>();

const concealOverrideField = StateField.define<boolean>({
  create: () => false,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setConcealOverride)) value = e.value;
    // Typing or keyboard selection always ends the override.
    if (tr.docChanged) return false;
    if (tr.selection && !tr.isUserEvent('select.pointer')) return false;
    return value;
  },
});

export function concealOverridden(state: EditorState): boolean {
  return state.field(concealOverrideField, false) ?? false;
}

/** The gesture settled or the double-click override toggled: rebuild. */
export function isGestureEffect(e: StateEffect<unknown>): boolean {
  return e.is(gestureSettled) || e.is(setConcealOverride);
}

function hasGestureEffect(update: ViewUpdate): boolean {
  return update.transactions.some((tr) => tr.effects.some(isGestureEffect));
}

/** A pointer-placed selection (CM6 tags mousedown and every drag update
 *  `select.pointer`), so a gesture may still be in progress. */
export function isPointerSelection(update: ViewUpdate): boolean {
  return update.transactions.some((tr) => tr.isUserEvent('select.pointer'));
}

// Device-global: widget press handlers in every editor ignore the compat
// mousedowns a touch synthesizes.
let lastTouchTime = 0;

export function recentTouch(): boolean {
  return Date.now() - lastTouchTime < 2000;
}

class PointerGestureTracker {
  private pointerDown = false;
  /** Frozen plugins await the release. */
  private pending = false;
  private widgetOpenGesture = false;
  private lastTextRevealTime = 0;
  private readonly onDocMouseUp: () => void;

  constructor(readonly view: EditorView) {
    // Document-level: drags often end outside the editor.
    this.onDocMouseUp = () => {
      this.pointerDown = false;
      if (!this.pending) return;
      const emptyCaret = this.view.state.selection.main.empty;
      this.settleNow();
      // Arm the undo only for a plain caret click into text.
      if (emptyCaret && !this.widgetOpenGesture) this.lastTextRevealTime = Date.now();
    };
    view.contentDOM.ownerDocument.addEventListener('mouseup', this.onDocMouseUp);
  }

  update(update: ViewUpdate) {
    if (hasGestureEffect(update) || update.docChanged) {
      this.pending = false;
      return;
    }
    if (!update.selectionSet) return;
    if (isPointerSelection(update)) {
      this.pending = true;
      // A pointer-tagged dispatch with the button already up (CM6's
      // press-in-selection release) must not freeze forever.
      if (!this.pointerDown) {
        queueMicrotask(() => {
          if (this.pending && !this.pointerDown) this.settleNow();
        });
      }
    } else {
      this.pending = false;
    }
  }

  destroy() {
    this.view.contentDOM.ownerDocument.removeEventListener('mouseup', this.onDocMouseUp);
  }

  noteMouseDown(event: MouseEvent) {
    this.pointerDown = true;
    const onWidget =
      event.target instanceof Element && !!event.target.closest(WIDGET_OPEN_SELECTOR);
    this.widgetOpenGesture = onWidget;
    if (
      event.detail >= 2 &&
      !event.shiftKey &&
      !onWidget &&
      Date.now() - this.lastTextRevealTime < DOUBLE_CLICK_UNDO_MS
    ) {
      // Now, before CM6's mousedown handler measures the click (observers run
      // first; dispatch applies decorations synchronously).
      this.view.dispatch({ effects: setConcealOverride.of(true) });
    }
  }

  private settleNow() {
    this.pending = false;
    this.view.dispatch({
      effects: [gestureSettled.of(null), setConcealOverride.of(false)],
    });
  }
}

export function pointerGestureExtension(): Extension {
  return [
    concealOverrideField,
    ViewPlugin.fromClass(PointerGestureTracker, {
      // Observers run before all handlers and can't cancel events.
      eventObservers: {
        mousedown(event) {
          this.noteMouseDown(event);
        },
        touchstart() {
          lastTouchTime = Date.now();
        },
      },
    }),
  ];
}
