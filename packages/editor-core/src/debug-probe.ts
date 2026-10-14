import { EditorView } from '@codemirror/view';
import type { Text } from '@codemirror/state';

/**
 * Reveal oracle: read-only probes over a live EditorView that recover the
 * observable reveal contract (what is hidden, which widgets stand in, what the
 * rendered lines must read) without re-implementing any plugin's predicate.
 * No dispatches, no DOM mutation. mount.ts exposes them behind the debug gate
 * as `window.__chalkDebugProbe`; vitest imports them directly.
 *
 * Decoration discriminators (CM6 internals): marks and line decorations have
 * no own `isReplace`; `PointDecoration` (behind both `Decoration.widget` and
 * `Decoration.replace`) sets `isReplace` (true for replace), `block` and
 * `widget`. So a hidden span is `isReplace === true && to > from`, and a
 * zero-width widget point is `isReplace === false`.
 */

export interface HiddenRange {
  from: number;
  to: number;
  /** True when any contributing replace was `block: true`. */
  block: boolean;
  /** Constructor name of the stand-in widget, or null for a bare hide. */
  widgetClass: string | null;
  /** Best-effort identifying text of the widget (pill text, latex, …). */
  widgetText: string | null;
}

interface WidgetPoint {
  pos: number;
  /** The spec's `side` (small integer), not CM6's internal bias encoding. */
  side: number;
  block: boolean;
  widgetClass: string | null;
}

interface AtomicRange {
  from: number;
  to: number;
}

interface VisibleLine {
  /** 1-based document line number the rendered row starts in. */
  line: number;
  /** The visible source text of that row (widget text excluded). */
  text: string;
}

interface ProbeSnapshot {
  head: number;
  anchor: number;
  empty: boolean;
  hidden: HiddenRange[];
  widgets: WidgetPoint[];
  atomic: AtomicRange[];
  visibleRanges: Array<{ from: number; to: number }>;
  domLines: VisibleLine[];
}

/** Runtime shape of a decoration value, per the discriminator notes above. */
interface DecoRuntime {
  point?: boolean;
  isReplace?: boolean;
  block?: boolean;
  widget?: { constructor?: { name?: string } } | null;
  spec?: { side?: number };
}

/** Best-effort identifying text of a widget, by common property name
 *  (text, latex, content, label, src, title). */
function widgetText(widget: unknown): string | null {
  if (!widget || typeof widget !== 'object') return null;
  const w = widget as Record<string, unknown>;
  for (const key of ['text', 'latex', 'content', 'label', 'src', 'title']) {
    if (typeof w[key] === 'string') return w[key] as string;
  }
  return null;
}

/** Every DecorationSet provided to the view, resolving the `(view) => set`
 *  thunks ViewPlugins provide. */
function decorationSets(view: EditorView): Array<{
  between: (
    from: number,
    to: number,
    f: (from: number, to: number, value: unknown) => void,
  ) => void;
}> {
  const values = view.state.facet(EditorView.decorations) as ReadonlyArray<unknown>;
  return values.map((v) => (typeof v === 'function' ? v(view) : v)) as ReturnType<
    typeof decorationSets
  >;
}

/**
 * All hidden source spans from every provider, sorted, with overlapping or
 * abutting spans merged (keeping the first widget's identity, ORing `block`).
 */
export function probeHidden(view: EditorView): HiddenRange[] {
  const raw: HiddenRange[] = [];
  for (const set of decorationSets(view)) {
    set.between(0, view.state.doc.length, (from, to, value) => {
      const v = value as DecoRuntime;
      if (v.isReplace !== true || to <= from) return;
      raw.push({
        from,
        to,
        block: v.block === true,
        widgetClass: v.widget?.constructor?.name ?? null,
        widgetText: widgetText(v.widget),
      });
    });
  }
  raw.sort((a, b) => a.from - b.from || a.to - b.to);
  const merged: HiddenRange[] = [];
  for (const r of raw) {
    const last = merged[merged.length - 1];
    if (last && r.from <= last.to) {
      last.to = Math.max(last.to, r.to);
      last.block = last.block || r.block;
      if (last.widgetClass === null) {
        last.widgetClass = r.widgetClass;
        last.widgetText = r.widgetText;
      }
    } else {
      merged.push({ ...r });
    }
  }
  return merged;
}

/** Zero-width widget insertion points (block math previews, etc.). */
export function probeWidgets(view: EditorView): WidgetPoint[] {
  const out: WidgetPoint[] = [];
  for (const set of decorationSets(view)) {
    set.between(0, view.state.doc.length, (from, to, value) => {
      const v = value as DecoRuntime;
      if (v.isReplace !== false || to !== from) return;
      out.push({
        pos: from,
        side: v.spec?.side ?? 0,
        block: v.block === true,
        widgetClass: v.widget?.constructor?.name ?? null,
      });
    });
  }
  out.sort((a, b) => a.pos - b.pos || a.side - b.side);
  return out;
}

/** Atomic ranges (currently only the GFM table block), sorted and merged. */
export function probeAtomic(view: EditorView): AtomicRange[] {
  const out: AtomicRange[] = [];
  for (const provider of view.state.facet(EditorView.atomicRanges)) {
    provider(view).between(0, view.state.doc.length, (from, to) => {
      if (to > from) out.push({ from, to });
    });
  }
  out.sort((a, b) => a.from - b.from || a.to - b.to);
  const merged: AtomicRange[] = [];
  for (const r of out) {
    const last = merged[merged.length - 1];
    if (last && r.from <= last.to) last.to = Math.max(last.to, r.to);
    else merged.push({ ...r });
  }
  return merged;
}

/**
 * The rendered lines the document plus hidden spans imply. A line covered by a
 * block replace yields no entry; a line whose leading newline is hidden joins
 * the previous entry (the collapsed-fence idiom).
 */
export function expectedVisibleLines(
  doc: Text,
  hidden: ReadonlyArray<Pick<HiddenRange, 'from' | 'to' | 'block'>>,
): VisibleLine[] {
  const out: VisibleLine[] = [];
  for (let n = 1; n <= doc.lines; n++) {
    const line = doc.line(n);
    const blockCovered = hidden.some(
      (h) => h.block && h.from <= line.from && h.to >= line.to,
    );
    if (blockCovered) continue;
    let text = '';
    let pos = line.from;
    for (const h of hidden) {
      if (h.to <= line.from) continue;
      if (h.from >= line.to) break;
      const clipFrom = Math.max(h.from, line.from);
      if (clipFrom > pos) text += doc.sliceString(pos, clipFrom);
      pos = Math.max(pos, Math.min(h.to, line.to));
    }
    if (pos < line.to) text += doc.sliceString(pos, line.to);
    const newlineHidden =
      line.from > 0 && hidden.some((h) => h.from <= line.from - 1 && h.to >= line.from);
    if (newlineHidden && out.length > 0) {
      out[out.length - 1].text += text;
    } else {
      out.push({ line: n, text });
    }
  }
  return out;
}

/**
 * The lines the DOM shows: each `.cm-line`'s text minus widget text
 * (`contenteditable="false"` subtrees, `.cm-widgetBuffer`). Compare with
 * `expectedVisibleLines`; works in jsdom too. Reads both the attribute and the
 * property: CM6 sets the property, which jsdom doesn't reflect.
 */
export function domVisibleLines(view: EditorView): VisibleLine[] {
  const notEditable = (el: Element): boolean =>
    el.getAttribute('contenteditable') === 'false' ||
    (el as HTMLElement & { contentEditable?: string }).contentEditable === 'false';
  const out: VisibleLine[] = [];
  for (const el of Array.from(view.contentDOM.querySelectorAll('.cm-line'))) {
    const pos = view.posAtDOM(el);
    const line = view.state.doc.lineAt(pos);
    let text = '';
    const walker = (el.ownerDocument ?? document).createTreeWalker(el, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      const node = walker.currentNode;
      let p = node.parentElement;
      let excluded = false;
      while (p && p !== el) {
        if (notEditable(p) || p.classList.contains('cm-widgetBuffer')) {
          excluded = true;
          break;
        }
        p = p.parentElement;
      }
      if (!excluded) text += node.textContent ?? '';
    }
    out.push({ line: line.number, text });
  }
  return out;
}

/** One-call state capture for the browser harness. */
export function probeSnapshot(view: EditorView): ProbeSnapshot {
  const main = view.state.selection.main;
  return {
    head: main.head,
    anchor: main.anchor,
    empty: main.empty,
    hidden: probeHidden(view),
    widgets: probeWidgets(view),
    atomic: probeAtomic(view),
    visibleRanges: view.visibleRanges.map((r) => ({ from: r.from, to: r.to })),
    domLines: domVisibleLines(view),
  };
}
