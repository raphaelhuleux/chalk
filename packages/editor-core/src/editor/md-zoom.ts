import {
  EditorSelection,
  EditorState,
  Prec,
  StateEffect,
  StateField,
  Transaction,
  type ChangeDesc,
  type Extension,
  type Range,
} from '@codemirror/state';
import { Decoration, EditorView, WidgetType, keymap, type Command } from '@codemirror/view';
import { mdHeadingTitle } from './outline';
import { ancestorsAt, outlineNodeAt, type OutlineNode } from './md-outline-tree';

/**
 * Zoom: show one heading section or list subtree and hide the rest, with a
 * breadcrumb bar above it. The hidden parts are whole-line block replaces, so
 * they have no rows; the bar is a block widget (padding only, no margins).
 *
 * The zoom follows the caret's intent: keyboard and pointer motion
 * (`select`, `select.pointer`, which includes Mod-Home) is clamped to the
 * zoomed range, while any other jump out of it (search, outline,
 * cross-reference) ends the zoom, so a jump never lands in hidden text.
 */

interface Zoom {
  /** Start of the root's first line and end of its last subtree line. */
  from: number;
  to: number;
}

/** Text typed at either edge stays inside the zoom. */
function mapZoom(z: Zoom, changes: ChangeDesc): Zoom {
  return { from: changes.mapPos(z.from, -1), to: changes.mapPos(z.to, 1) };
}

const setZoom = StateEffect.define<Zoom | null>({
  map: (z, m) => (z ? mapZoom(z, m) : null),
});

export const zoomField = StateField.define<Zoom | null>({
  create: () => null,
  update(zoom, tr) {
    for (const e of tr.effects) if (e.is(setZoom)) return e.value;
    if (!zoom) return zoom;
    // Same object when nothing moved, so the decorations aren't rebuilt.
    const next = tr.docChanged ? mapZoom(zoom, tr.changes) : zoom;
    if (next.to <= next.from) return null;
    const head = tr.state.selection.main.head;
    if (tr.selection && (head < next.from || head > next.to)) return null;
    return next;
  },
});

/** Keyboard and pointer motion stays inside the zoom; other jumps end it. */
const clampMotion = EditorState.transactionFilter.of((tr) => {
  const zoom = tr.startState.field(zoomField, false);
  if (!zoom || !tr.selection || tr.docChanged) return tr;
  const ue = tr.annotation(Transaction.userEvent);
  if (ue !== 'select' && ue !== 'select.pointer') return tr;
  const clamp = (p: number) => Math.min(zoom.to, Math.max(zoom.from, p));
  const ranges = tr.selection.ranges.map((r) =>
    EditorSelection.range(clamp(r.anchor), clamp(r.head)),
  );
  return [tr, { selection: EditorSelection.create(ranges, tr.selection.mainIndex), sequential: true }];
});

function titleOf(state: EditorState, node: OutlineNode): string {
  const text = state.doc.line(node.line).text;
  // A Setext title line has no `#`s; mdHeadingTitle only strips what is there.
  const title = node.item ? text.slice(node.item.bodyOffset).trim() : mdHeadingTitle(text);
  return title.length > 40 ? `${title.slice(0, 39)}…` : title || '(untitled)';
}

class ZoomBar extends WidgetType {
  constructor(readonly crumbs: { title: string; line: number }[]) {
    super();
  }

  eq(other: ZoomBar): boolean {
    return (
      other.crumbs.length === this.crumbs.length &&
      other.crumbs.every((c, i) => c.title === this.crumbs[i].title && c.line === this.crumbs[i].line)
    );
  }

  toDOM(view: EditorView): HTMLElement {
    const bar = document.createElement('div');
    bar.className = 'cm-md-zoom-bar';
    const add = (label: string, onClick: (() => void) | null) => {
      const el = document.createElement('span');
      el.className = onClick ? 'cm-md-zoom-crumb' : 'cm-md-zoom-crumb cm-md-zoom-current';
      el.textContent = label;
      if (onClick) {
        el.addEventListener('mousedown', (e) => {
          e.preventDefault();
          onClick();
        });
      }
      bar.appendChild(el);
    };
    add('Document', () => zoomOut(view));
    this.crumbs.forEach((c, i) => {
      const sep = document.createElement('span');
      sep.className = 'cm-md-zoom-sep';
      sep.textContent = '›';
      bar.appendChild(sep);
      const last = i === this.crumbs.length - 1;
      add(c.title, last ? null : () => zoomToLine(view, c.line));
    });
    return bar;
  }

  ignoreEvent(): boolean {
    return true;
  }
}

const zoomDecorations = EditorView.decorations.compute([zoomField], (state) => {
  const zoom = state.field(zoomField);
  if (!zoom) return Decoration.none;
  const { doc } = state;
  const first = doc.lineAt(zoom.from);
  const last = doc.lineAt(zoom.to);
  const decos: Range<Decoration>[] = [];
  if (first.number > 1) {
    decos.push(Decoration.replace({ block: true }).range(0, doc.line(first.number - 1).to));
  }
  const crumbs = ancestorsAt(state, first.number).map((n) => ({
    title: titleOf(state, n),
    line: n.line,
  }));
  decos.push(Decoration.widget({ widget: new ZoomBar(crumbs), block: true, side: -1 }).range(first.from));
  if (last.number < doc.lines) {
    decos.push(Decoration.replace({ block: true }).range(doc.line(last.number + 1).from, doc.length));
  }
  return Decoration.set(decos, true);
});

function zoomToLine(view: EditorView, lineNo: number): boolean {
  const node = outlineNodeAt(view.state, lineNo);
  if (!node) return false;
  const { doc } = view.state;
  const zoom = { from: doc.line(node.line).from, to: doc.line(node.end).to };
  const head = view.state.selection.main.head;
  const inside = head >= zoom.from && head <= zoom.to;
  view.dispatch({
    effects: setZoom.of(zoom),
    selection: inside ? undefined : EditorSelection.cursor(doc.line(node.line).to),
    scrollIntoView: true,
  });
  return true;
}

/** Zoom into the innermost heading or item with children around the caret. */
export const zoomIn: Command = (view) => {
  const { state } = view;
  const line = state.doc.lineAt(state.selection.main.head).number;
  const chain = ancestorsAt(state, line);
  const zoom = state.field(zoomField, false);
  // A leaf has nothing to focus on: its parent is the innermost subtree.
  const target = [...chain].reverse().find((n) => n.end > n.headEnd) ?? chain[chain.length - 1];
  if (!target) return false;
  // Already zoomed there: nothing deeper to show.
  if (zoom && zoom.from === state.doc.line(target.line).from) return true;
  return zoomToLine(view, target.line);
};

export const zoomOut: Command = (view) => {
  if (!view.state.field(zoomField, false)) return false;
  view.dispatch({ effects: setZoom.of(null), scrollIntoView: true });
  return true;
};

const zoomTheme = EditorView.baseTheme({
  '.cm-md-zoom-bar': {
    padding: '0.4em 0 0.6em',
    fontSize: '0.85em',
    opacity: 0.75,
    display: 'flex',
    flexWrap: 'wrap',
    gap: '0.4em',
    alignItems: 'baseline',
  },
  '.cm-md-zoom-crumb': { cursor: 'pointer' },
  '.cm-md-zoom-crumb:hover': { textDecoration: 'underline' },
  '.cm-md-zoom-current': { cursor: 'default', fontWeight: '600' },
  '.cm-md-zoom-current:hover': { textDecoration: 'none' },
  '.cm-md-zoom-sep': { opacity: 0.6 },
});

export function mdZoomExtension(): Extension {
  return [
    zoomField,
    // Above the preview sets: the hidden lines win over any widget inside them.
    Prec.highest(zoomDecorations),
    clampMotion,
    zoomTheme,
    keymap.of([{ key: 'Mod-.', run: zoomIn }]),
    // Last in line for Escape: completion, snippets and search keep theirs.
    Prec.lowest(keymap.of([{ key: 'Escape', run: zoomOut }])),
  ];
}
