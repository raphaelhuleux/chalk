import {
  Decoration,
  type DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
} from '@codemirror/view';
import { Compartment, type Extension, RangeSetBuilder } from '@codemirror/state';

import type { EditingMode } from './theme';
import { isPointerSelection } from './pointer-gesture';

/**
 * Editing modes: `typewriter` keeps the caret line centered and dims other
 * lines; `focus` dims all but the current sentence. Own compartment, not the
 * theme's, so toggling a mode doesn't rebuild the theme.
 */
export const editingModeCompartment = new Compartment();

/**
 * Scoped to the wrapper's `.cm-typewriter` class so these selectors (0,3,0)
 * out-rank host overrides like `.editor-host .cm-content` (0,2,0). The vertical
 * padding lets the first and last lines reach the center; horizontal padding
 * is left to the host.
 */
const typewriterTheme = EditorView.theme({
  '&.cm-typewriter .cm-content': {
    paddingTop: '48vh',
    paddingBottom: '48vh',
  },
  '&.cm-typewriter .cm-dim': {
    opacity: '0.4',
    transition: 'opacity 0.15s ease',
  },
});

const focusTheme = EditorView.theme({
  '&.cm-focus .cm-dim': {
    opacity: '0.4',
    transition: 'opacity 0.15s ease',
  },
});

const dimMark = Decoration.mark({ class: 'cm-dim' });

const SENTENCE_END = /[.!?]/;
const CLOSERS = /["')\]]/;
const SPACE = /\s/;

/** `text[i]` is `.!?` followed (after closers) by whitespace or line end, so
 *  mid-word dots like `e.g.` don't count. Exported for tests. */
export function isSentenceEnd(text: string, i: number): boolean {
  if (!SENTENCE_END.test(text[i])) return false;
  let j = i + 1;
  while (j < text.length && CLOSERS.test(text[j])) j++;
  return j >= text.length || SPACE.test(text[j]);
}

/** Document range of the sentence containing `pos`, bounded to `pos`'s line (a
 *  soft-wrapped paragraph is one line). Exported for tests. */
export function sentenceRangeAt(doc: { lineAt(pos: number): { from: number; text: string } }, pos: number): {
  from: number;
  to: number;
} {
  const line = doc.lineAt(pos);
  const text = line.text;
  const rel = pos - line.from;

  let start = 0;
  for (let i = Math.min(rel, text.length) - 1; i >= 0; i--) {
    if (isSentenceEnd(text, i)) {
      start = i + 1;
      while (start < text.length && SPACE.test(text[start])) start++;
      break;
    }
  }

  let end = text.length;
  for (let i = Math.max(0, rel); i < text.length; i++) {
    if (isSentenceEnd(text, i)) {
      end = i + 1;
      while (end < text.length && CLOSERS.test(text[end])) end++;
      break;
    }
  }

  return { from: line.from + start, to: line.from + end };
}

type Doc = { lineAt(pos: number): { from: number; to: number; text: string } };

/**
 * Dim all but a kept range around the selection, only across visibleRanges so
 * cost is viewport-bounded. Marks, not line decorations: focus keeps a slice
 * within a line, and a container's opacity can't be undone for a child.
 */
function dimPlugin(
  keepRange: (doc: Doc, from: number, to: number) => { from: number; to: number },
) {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;

      constructor(view: EditorView) {
        this.decorations = this.build(view);
      }

      update(u: ViewUpdate): void {
        if (u.docChanged || u.selectionSet || u.viewportChanged) {
          this.decorations = this.build(u.view);
        }
      }

      private build(view: EditorView): DecorationSet {
        const { doc, selection } = view.state;
        const sel = selection.main;
        const { from: keepFrom, to: keepTo } = keepRange(doc, sel.from, sel.to);
        const builder = new RangeSetBuilder<Decoration>();
        for (const { from, to } of view.visibleRanges) {
          const leftTo = Math.min(to, Math.max(from, keepFrom));
          if (leftTo > from) builder.add(from, leftTo, dimMark);
          const rightFrom = Math.max(from, Math.min(to, keepTo));
          if (to > rightFrom) builder.add(rightFrom, to, dimMark);
        }
        return builder.finish();
      }
    },
    { decorations: (v) => v.decorations },
  );
}

const focusDimPlugin = dimPlugin((doc, from, to) => {
  let keepFrom = sentenceRangeAt(doc, from).from;
  let keepTo = sentenceRangeAt(doc, to).to;
  // No sentence on a blank line: keep the line so it isn't dimmed before typing.
  if (keepTo <= keepFrom) {
    keepFrom = doc.lineAt(from).from;
    keepTo = doc.lineAt(to).to;
  }
  return { from: keepFrom, to: keepTo };
});

const lineDimPlugin = dimPlugin((doc, from, to) => ({
  from: doc.lineAt(from).from,
  to: doc.lineAt(to).to,
}));

/**
 * Re-center the caret line on every move. The scroll effect sets neither
 * docChanged nor selectionSet, so it doesn't loop; the rAF is needed because
 * CM6 forbids dispatching inside update(), and coalesces keystroke bursts.
 *
 * Never center mid-gesture: MouseSelection re-resolves the head from screen
 * coordinates on every move, so a scroll under a pressed button turns a click
 * into a paragraph-wide drag-select (pinned in Tests/browser/run.mjs). Pointer
 * moves are centered at release by `centerOnGestureEnd` instead.
 */
const centerPlugin = ViewPlugin.fromClass(
  class {
    private raf = 0;
    private pressX = NaN;
    private pressY = NaN;

    constructor(private readonly view: EditorView) {
      this.schedule(); // center immediately when the mode turns on
    }

    update(u: ViewUpdate): void {
      if (!u.docChanged && !u.selectionSet) return; // ignore our own scroll
      if (!u.state.selection.main.empty) return; // don't fight a drag-select
      if (isPointerSelection(u)) return; // centered at release, not mid-gesture
      this.schedule();
    }

    /** NaN means no press seen (the pointer entered already down). */
    notePress(x: number, y: number): void {
      this.pressX = x;
      this.pressY = y;
    }

    /** Center only for a click (within CLICK_SLOP_PX), even if CM6's missing
     *  drag threshold selected a stray character; a real drag stays put. */
    noteRelease(x: number, y: number): void {
      const moved = Math.max(Math.abs(x - this.pressX), Math.abs(y - this.pressY));
      this.pressX = NaN;
      this.pressY = NaN;
      if (moved <= CLICK_SLOP_PX) this.schedule(true);
    }

    schedule(wasClick = false): void {
      cancelAnimationFrame(this.raf);
      this.raf = requestAnimationFrame(() => {
        const sel = this.view.state.selection.main;
        if (!sel.empty && !wasClick) return; // don't fight a drag-select
        this.view.dispatch({ effects: EditorView.scrollIntoView(sel.head, { y: 'center' }) });
      });
    }

    destroy(): void {
      cancelAnimationFrame(this.raf);
    }
  },
);

// Press-to-release travel still counted as a click (tremor, trackpad noise).
const CLICK_SLOP_PX = 4;

/** Center after release, when geometry is safe to move. Touch covers
 *  touchscreen taps (also `select.pointer`). Handlers return falsy so CM6 still sees the
 *  events. */
const centerOnGestureEnd = EditorView.domEventHandlers({
  mousedown(event, view) {
    view.plugin(centerPlugin)?.notePress(event.clientX, event.clientY);
  },
  mouseup(event, view) {
    view.plugin(centerPlugin)?.noteRelease(event.clientX, event.clientY);
  },
  touchstart(event, view) {
    const t = event.touches[0];
    if (t) view.plugin(centerPlugin)?.notePress(t.clientX, t.clientY);
  },
  touchend(event, view) {
    const t = event.changedTouches[0];
    if (t) view.plugin(centerPlugin)?.noteRelease(t.clientX, t.clientY);
  },
});

function typewriterExtension(): Extension {
  return [
    EditorView.editorAttributes.of({ class: 'cm-typewriter' }),
    typewriterTheme,
    centerPlugin,
    centerOnGestureEnd,
    lineDimPlugin,
  ];
}

function focusExtension(): Extension {
  return [
    EditorView.editorAttributes.of({ class: 'cm-focus' }),
    focusTheme,
    focusDimPlugin,
  ];
}

/** The extension for a host-selected editing mode. `normal` needs nothing;
 *  `zen` is chrome-hiding implemented entirely by the host shell. */
export function editingModeExtension(mode: EditingMode): Extension {
  switch (mode) {
    case 'typewriter':
      return typewriterExtension();
    case 'focus':
      return focusExtension();
    default:
      return [];
  }
}
