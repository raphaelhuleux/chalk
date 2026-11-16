/**
 * AI marks: text that arrived from outside the editor, tinted until the user
 * accepts or edits it. Nothing here reads the selection or feeds the conceal
 * builders, so marks can't change reveal (caret spec O-5), and the paint is
 * `layer()`s rather than decorations: a layer covers text, inline math and
 * block widgets alike, and adds no caret stop (R-S1).
 *
 * Marking is opt-in per write: only an `update` carrying `origin: 'external'`
 * adds marks. Every other doc change is unmarked text, which is why typing
 * inside a mark splits it.
 */
import { invertedEffects } from '@codemirror/commands';
import {
  type ChangeDesc,
  Compartment,
  EditorSelection,
  type EditorState,
  type Extension,
  MapMode,
  StateEffect,
  StateField,
  Transaction,
} from '@codemirror/state';
import {
  type BlockInfo,
  BlockType,
  type EditorView,
  type LayerMarker,
  RectangleMarker,
  closeHoverTooltips,
  hoverTooltip,
  layer,
  type ViewUpdate,
} from '@codemirror/view';
import type { Hunk } from '../utils/word-diff';

/** `[from, to)` is AI text; `deleted` is the human text it replaced, restored
 *  by Reject. `from === to` is a deletion with nothing written in its place. */
export interface AiMark {
  from: number;
  to: number;
  deleted: string;
}

/** Replaces the whole set. Values are in post-transaction coordinates. */
const setMarksEffect = StateEffect.define<readonly AiMark[]>({
  map: (marks, changes) => normalize(mapUnmarked(marks, changes)),
});

/** One outside write, with the hunks its transaction applies. */
export const aiWriteEffect = StateEffect.define<readonly Hunk[]>();

/** Sorted, with touching marks joined: no kept text lies between them, so
 *  Reject can restore their deleted text in one place. */
function normalize(marks: AiMark[]): AiMark[] {
  marks.sort((a, b) => a.from - b.from || a.to - b.to);
  const out: AiMark[] = [];
  for (const m of marks) {
    const last = out[out.length - 1];
    if (last && m.from <= last.to) {
      last.to = Math.max(last.to, m.to);
      last.deleted += m.deleted;
    } else {
      out.push({ ...m });
    }
  }
  return out;
}

/** Cut `spans` out of `marks`. `RangeSet.map`-style mapping stretches a mark
 *  around an interior insertion, and that text isn't the AI's. */
function subtract(marks: AiMark[], spans: readonly [number, number][]): AiMark[] {
  if (spans.length === 0) return marks;
  const out: AiMark[] = [];
  for (const mark of marks) {
    let start = mark.from;
    const pieces: AiMark[] = [];
    for (const [from, to] of spans) {
      if (to <= start || from >= mark.to) continue;
      if (from > start) pieces.push({ from: start, to: from, deleted: '' });
      start = Math.max(start, to);
    }
    if (start < mark.to) pieces.push({ from: start, to: mark.to, deleted: '' });
    if (pieces.length > 0) pieces[0].deleted = mark.deleted;
    else if (mark.deleted) pieces.push({ from: mark.from, to: mark.from, deleted: mark.deleted });
    out.push(...pieces);
  }
  return out;
}

function mapMark(mark: AiMark, changes: ChangeDesc): AiMark | null {
  if (mark.from === mark.to) {
    const at = changes.mapPos(mark.from, 1, MapMode.TrackDel);
    return at === null ? null : { ...mark, from: at, to: at };
  }
  const from = changes.mapPos(mark.from, 1);
  const to = changes.mapPos(mark.to, -1);
  if (from < to) return { ...mark, from, to };
  return mark.deleted ? { ...mark, from, to: from } : null;
}

/** Marks through a change that wrote no AI text. */
function mapUnmarked(marks: readonly AiMark[], changes: ChangeDesc): AiMark[] {
  const mapped = marks.flatMap((m) => mapMark(m, changes) ?? []);
  const inserted: [number, number][] = [];
  changes.iterChangedRanges((_fromA, _toA, fromB, toB) => {
    if (toB > fromB) inserted.push([fromB, toB]);
  });
  return subtract(mapped, inserted);
}

/** What a hunk removed that a Reject must bring back: human text, plus the
 *  `deleted` of any mark the hunk swallows. AI text replacing AI text leaves
 *  nothing to restore. */
function humanTextIn(hunk: Hunk, marks: readonly AiMark[], state: EditorState): string {
  let at = hunk.fromA;
  let out = '';
  for (const m of marks) {
    if (m.to < hunk.fromA || m.from > hunk.toA) continue;
    const start = Math.max(m.from, hunk.fromA);
    const end = Math.min(m.to, hunk.toA);
    if (start > at) out += state.sliceDoc(at, start);
    if (isInside(m, hunk)) out += m.deleted;
    at = Math.max(at, end);
  }
  return at < hunk.toA ? out + state.sliceDoc(at, hunk.toA) : out;
}

const isInside = (mark: AiMark, hunk: Hunk): boolean =>
  mark.from >= hunk.fromA && mark.to <= hunk.toA;

function applyWrite(marks: readonly AiMark[], hunks: readonly Hunk[], tr: Transaction): AiMark[] {
  // A mark inside a hunk hands its `deleted` to the hunk (humanTextIn).
  const kept = marks.filter((m) => !hunks.some((h) => isInside(m, h)));
  const out = kept.flatMap((m) => mapMark(m, tr.changes) ?? []);
  for (const hunk of hunks) {
    const deleted = humanTextIn(hunk, marks, tr.startState);
    if (hunk.toB > hunk.fromB || deleted) {
      out.push({ from: hunk.fromB, to: hunk.toB, deleted });
    }
  }
  return normalize(out);
}

const marksField = StateField.define<readonly AiMark[]>({
  create: () => [],
  update(marks, tr) {
    let write: readonly Hunk[] | null = null;
    for (const e of tr.effects) {
      if (e.is(setMarksEffect)) return e.value;
      if (e.is(aiWriteEffect)) write = e.value;
    }
    if (write) return applyWrite(marks, write, tr);
    if (!tr.docChanged || marks.length === 0) return marks;
    return normalize(mapUnmarked(marks, tr.changes));
  },
});

/** Accept and Reject undo as snapshots, so Cmd+Z brings the marks back too. */
const undoableMarks = invertedEffects.of((tr) =>
  tr.effects.some((e) => e.is(setMarksEffect))
    ? [setMarksEffect.of(tr.startState.field(marksField))]
    : [],
);

// ── Commands ────────────────────────────────────────────────────────

export function getAiMarks(state: EditorState): readonly AiMark[] {
  return state.field(marksField, false) ?? [];
}

/** The marks an Accept or Reject acts on: those the selection touches, or all
 *  of them with no selection. */
function marksInScope(state: EditorState): readonly AiMark[] {
  const marks = getAiMarks(state);
  const ranges = state.selection.ranges.filter((r) => !r.empty);
  if (ranges.length === 0) return marks;
  return marks.filter((m) => ranges.some((r) => m.from <= r.to && m.to >= r.from));
}

function acceptMarks(view: EditorView, targets: readonly AiMark[]): boolean {
  if (targets.length === 0) return false;
  const remaining = getAiMarks(view.state).filter((m) => !targets.includes(m));
  view.dispatch({ effects: setMarksEffect.of(remaining), userEvent: 'ai.accept' });
  return true;
}

function rejectMarks(view: EditorView, targets: readonly AiMark[]): boolean {
  if (targets.length === 0) return false;
  const changes = view.state.changes(
    targets.map((m) => ({ from: m.from, to: m.to, insert: m.deleted })),
  );
  const remaining = getAiMarks(view.state).filter((m) => !targets.includes(m));
  view.dispatch({
    changes,
    effects: setMarksEffect.of(normalize(mapUnmarked(remaining, changes))),
    userEvent: 'ai.reject',
  });
  return true;
}

/** Keep the text, clear its mark. */
export const acceptAiMarks = (view: EditorView): boolean =>
  acceptMarks(view, marksInScope(view.state));

/** Drop the AI text and restore what it deleted. */
export const rejectAiMarks = (view: EditorView): boolean =>
  rejectMarks(view, marksInScope(view.state));

/** Marks from the host's store. It may hold anything, so a range that doesn't
 *  fit this document is dropped. Not undoable: it isn't a user action. */
export function restoreAiMarks(view: EditorView, marks: readonly AiMark[]): void {
  const length = view.state.doc.length;
  const valid = marks.filter(
    (m) =>
      Number.isInteger(m.from) &&
      Number.isInteger(m.to) &&
      m.from >= 0 &&
      m.from <= m.to &&
      m.to <= length &&
      typeof m.deleted === 'string' &&
      (m.from < m.to || m.deleted !== ''),
  );
  view.dispatch({
    effects: setMarksEffect.of(normalize([...valid])),
    annotations: Transaction.addToHistory.of(false),
  });
}

// ── Paint ───────────────────────────────────────────────────────────

/** Screen-to-layer offset; layers are positioned inside the scroller. */
function layerOrigin(view: EditorView): { x: number; y: number } {
  const box = view.scrollDOM.getBoundingClientRect();
  return {
    x: box.left - view.scrollDOM.scrollLeft * view.scaleX,
    y: box.top - view.scrollDOM.scrollTop * view.scaleY,
  };
}

function widgetWash(view: EditorView, block: BlockInfo): LayerMarker {
  const origin = layerOrigin(view);
  const content = view.contentDOM.getBoundingClientRect();
  return new RectangleMarker(
    'cm-aiMark',
    (content.left - origin.x) / view.scaleX,
    (view.documentTop + block.top * view.scaleY - origin.y) / view.scaleY,
    content.width / view.scaleX,
    block.height,
  );
}

/** Line by line, not one `forRange` over the mark: that leaves out a block
 *  widget at either end of its range and fills every row to the right edge,
 *  where the wash should hug the text. */
function washMarkers(view: EditorView): readonly LayerMarker[] {
  const marks = view.state.field(marksField);
  if (marks.length === 0) return [];
  const out: LayerMarker[] = [];
  for (const line of view.viewportLineBlocks) {
    for (const block of Array.isArray(line.type) ? line.type : [line]) {
      for (const m of marks) {
        if (m.to <= block.from || m.from >= block.to) {
          // A widget above or below a line is a point: it belongs to a mark
          // that runs through that point.
          const point = block.from === block.to && m.from <= block.from && m.to >= block.to;
          if (!point || block.type === BlockType.Text) continue;
        }
        if (block.type !== BlockType.Text) {
          out.push(widgetWash(view, block));
          break;
        }
        const from = Math.max(m.from, block.from);
        const to = Math.min(m.to, block.to);
        // A blank line has nothing to wash, and beside a block widget `forRange` measures the
        // widget's box there, painting a strip as wide as the widget into the margin.
        if (from === to) continue;
        out.push(...RectangleMarker.forRange(view, 'cm-aiMark', EditorSelection.range(from, to)));
      }
    }
  }
  return out;
}

const marksLayerNeedsUpdate = (update: ViewUpdate): boolean =>
  update.docChanged ||
  update.viewportChanged ||
  update.geometryChanged ||
  update.startState.field(marksField) !== update.state.field(marksField);

const washLayer = layer({
  above: false,
  class: 'cm-aiMarkLayer',
  update: marksLayerNeedsUpdate,
  markers: washMarkers,
});

/** A tick where text was removed. `forRange` draws nothing for an empty range,
 *  and an inline widget would add a caret stop, so it is placed by hand. */
const deletionLayer = layer({
  above: true,
  class: 'cm-aiDeletionLayer',
  update: marksLayerNeedsUpdate,
  markers(view) {
    const { from, to } = view.viewport;
    const origin = layerOrigin(view);
    const out: LayerMarker[] = [];
    for (const m of view.state.field(marksField)) {
      if (!m.deleted || m.from < from || m.from > to) continue;
      const at = view.coordsAtPos(m.from, 1) ?? view.coordsAtPos(m.from, -1);
      if (!at) continue;
      out.push(
        new RectangleMarker(
          'cm-aiDeletion',
          (at.left - origin.x) / view.scaleX,
          (at.top - origin.y) / view.scaleY,
          null,
          (at.bottom - at.top) / view.scaleY,
        ),
      );
    }
    return out;
  },
});

function reviewTooltip(view: EditorView, mark: AiMark): HTMLElement {
  const dom = document.createElement('div');
  dom.className = 'cm-aiReview';
  if (mark.deleted) {
    const label = document.createElement('span');
    label.className = 'cm-aiReview-label';
    label.textContent = 'Removed';
    const old = document.createElement('s');
    old.className = 'cm-aiReview-text';
    old.textContent = mark.deleted;
    dom.append(label, old);
  }
  const button = (text: string, run: (marks: readonly AiMark[]) => void): HTMLButtonElement => {
    const el = document.createElement('button');
    el.type = 'button';
    el.textContent = text;
    // mousedown, not click: keeps the editor's focus and selection.
    el.addEventListener('mousedown', (event) => {
      event.preventDefault();
      // By range: a menu Accept can drop the mark while this stands, and a
      // stale press must not reach another mark.
      run(getAiMarks(view.state).filter((m) => m.from === mark.from && m.to === mark.to));
      view.dispatch({ effects: closeHoverTooltips });
    });
    return el;
  };
  dom.append(
    button('Accept', (marks) => acceptMarks(view, marks)),
    button('Reject', (marks) => rejectMarks(view, marks)),
  );
  return dom;
}

/** Accept and Reject on every mark, plus the old text where there is some. */
const reviewHover = hoverTooltip(
  (view, pos) => {
    // Only an empty mark, a lone tick, needs slack: elsewhere it would claim
    // the character beside the wash.
    const mark = view.state.field(marksField).find((m) => {
      const slack = m.from === m.to ? 1 : 0;
      return pos >= m.from - slack && pos <= m.to + slack;
    });
    if (!mark) return null;
    // Anchored on the hovered line: the start of a long mark may be off screen.
    const lineStart = view.state.doc.lineAt(pos).from;
    return {
      pos: Math.min(Math.max(mark.from, lineStart), mark.to),
      end: mark.to,
      above: true,
      create: () => ({ dom: reviewTooltip(view, mark) }),
    };
  },
  { hoverTime: 350, hideOnChange: true },
);

// ── Extensions ──────────────────────────────────────────────────────

/** Whether marks paint. Off keeps tracking them: hiding is for reading, and
 *  must not lose anything. */
export const aiMarksPaintCompartment = new Compartment();

export function aiMarksPaint(show: 'show' | 'hide'): Extension {
  return show === 'show' ? [washLayer, deletionLayer, reviewHover] : [];
}

export function aiMarksExtension(): Extension {
  return [marksField, undoableMarks];
}
