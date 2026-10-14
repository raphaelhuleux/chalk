import { ChangeSpec, EditorSelection, EditorState, Extension } from '@codemirror/state';
import { indentUnit } from '@codemirror/language';
import { EditorView, keymap } from '@codemirror/view';
import { MD_BULLET_RE } from './md-list-newline';

/**
 * Tab / Shift+Tab on an ordered Markdown list item. `indentWithTab` is
 * marker-blind, so a freshly nested item would keep its old number. This
 * re-indents the line, numbers it after the nearest sibling at its new depth
 * (1 if none), and renumbers the run it left so it stays contiguous:
 *
 *     1. a          Tab on b      1. a
 *     2. b          ──────────→       1. b
 *     3. c                        2. c
 *
 * Only an `N.` / `N)` item with an empty selection outside math is claimed;
 * everything else falls through to `indentWithTab`.
 *
 * Two rules Markdown doesn't settle:
 *  - The list block is walked line by line: list items continue it, and so
 *    does a non-list line deeper than the last item (a continuation). A blank
 *    line or a paragraph at or left of that indent ends it.
 *  - A bullet at the same depth ends the sibling run and is never rewritten.
 */

// indent | number | delimiter | gap | body.
const MD_ORDERED_RE = /^([ \t]*)(\d+)([.)])([ \t]+)(.*)$/;

interface OrderedItem {
  indent: string;
  num: number;
  delim: string;
  gap: string;
}

function parseOrdered(text: string): OrderedItem | null {
  const m = text.match(MD_ORDERED_RE);
  if (!m) return null;
  return { indent: m[1], num: parseInt(m[2], 10), delim: m[3], gap: m[4] };
}

function leadingWhitespace(text: string): string {
  const m = text.match(/^[ \t]*/);
  return m ? m[0] : '';
}

/** Ordered item, bullet item, or neither. */
function listKind(text: string): 'ordered' | 'bullet' | null {
  if (MD_ORDERED_RE.test(text)) return 'ordered';
  if (MD_BULLET_RE.test(text)) return 'bullet';
  return null;
}

/** Indent in columns, a tab counting as one whole indent unit. */
function indentWidth(indent: string, unit: string): number {
  let w = 0;
  for (const c of indent) w += c === '\t' ? unit.length : 1;
  return w;
}

/** First and last line number (inclusive) of the list block holding `lineNo`. */
function listBlockBounds(
  state: EditorState,
  lineNo: number,
  unit: string,
): { from: number; to: number } {
  const width = (n: number) => indentWidth(leadingWhitespace(state.doc.line(n).text), unit);
  const scan = (dir: -1 | 1): number => {
    let last = lineNo;
    let itemWidth = width(lineNo);
    for (let n = lineNo + dir; n >= 1 && n <= state.doc.lines; n += dir) {
      const text = state.doc.line(n).text;
      if (text.trim().length === 0) break;
      const kind = listKind(text);
      if (kind === null) {
        if (indentWidth(leadingWhitespace(text), unit) <= itemWidth) break;
      } else {
        itemWidth = indentWidth(leadingWhitespace(text), unit);
      }
      last = n;
    }
    return last;
  };
  return { from: scan(-1), to: scan(1) };
}

/**
 * Number of the nearest ordered sibling above `lineNo` at `targetWidth`, or 0
 * if none. A shallower item (the parent) or a same-depth bullet ends the search.
 */
function precedingSiblingNumber(
  state: EditorState,
  blockFrom: number,
  lineNo: number,
  targetWidth: number,
  unit: string,
): number {
  for (let n = lineNo - 1; n >= blockFrom; n--) {
    const text = state.doc.line(n).text;
    const kind = listKind(text);
    if (kind === null) continue; // continuation line
    const w = indentWidth(leadingWhitespace(text), unit);
    if (w > targetWidth) continue;
    if (w < targetWidth) return 0;
    if (kind === 'bullet') return 0;
    return parseOrdered(text)!.num;
  }
  return 0;
}

/**
 * Renumber the ordered siblings below `lineNo` at `targetWidth` from `start`.
 * Keyed by line number so the two passes (new depth, old depth) can't collide.
 */
function renumberFollowing(
  state: EditorState,
  blockTo: number,
  lineNo: number,
  targetWidth: number,
  start: number,
  unit: string,
): Map<number, ChangeSpec> {
  const out = new Map<number, ChangeSpec>();
  let next = start;
  for (let n = lineNo + 1; n <= blockTo; n++) {
    const line = state.doc.line(n);
    const kind = listKind(line.text);
    if (kind === null) continue; // continuation line
    const w = indentWidth(leadingWhitespace(line.text), unit);
    if (w > targetWidth) continue;
    if (w < targetWidth) break;
    if (kind === 'bullet') break;
    const item = parseOrdered(line.text)!;
    if (item.num !== next) {
      const from = line.from + item.indent.length;
      out.set(n, { from, to: from + String(item.num).length, insert: String(next) });
    }
    next++;
  }
  return out;
}

/** Indent for one step in `dir`, or null when a dedent has nothing to remove. */
function shiftIndent(indent: string, unit: string, dir: 1 | -1): string | null {
  if (dir === 1) return indent + unit;
  if (indent.length === 0) return null;
  // Trim from the END so a leading tab survives a space-unit dedent.
  if (indent.endsWith(unit)) return indent.slice(0, indent.length - unit.length);
  if (indent.endsWith('\t')) return indent.slice(0, -1);
  return indent.slice(0, Math.max(0, indent.length - unit.length));
}

function mdOrderedIndentRun(
  view: EditorView,
  isInMathContext: (state: EditorState, pos: number) => boolean,
  dir: 1 | -1,
): boolean {
  const { state } = view;
  const sel = state.selection.main;
  if (!sel.empty) return false;
  const pos = sel.head;
  if (isInMathContext(state, pos)) return false;

  const line = state.doc.lineAt(pos);
  const item = parseOrdered(line.text);
  if (!item) return false;

  const unit = state.facet(indentUnit);
  const newIndent = shiftIndent(item.indent, unit, dir);
  if (newIndent === null) return false;

  const oldWidth = indentWidth(item.indent, unit);
  const newWidth = indentWidth(newIndent, unit);
  const block = listBlockBounds(state, line.number, unit);

  const newNum = precedingSiblingNumber(state, block.from, line.number, newWidth, unit) + 1;
  const markerEnd = line.from + item.indent.length + String(item.num).length + item.delim.length;
  const changes = new Map<number, ChangeSpec>([
    [line.number, { from: line.from, to: markerEnd, insert: `${newIndent}${newNum}${item.delim}` }],
  ]);

  // The run the item joins, then the run it left, each numbered from what sits
  // above it, so a middle item's departure closes the gap.
  const oldStart = precedingSiblingNumber(state, block.from, line.number, oldWidth, unit) + 1;
  for (const [n, change] of renumberFollowing(
    state,
    block.to,
    line.number,
    newWidth,
    newNum + 1,
    unit,
  )) {
    changes.set(n, change);
  }
  if (newWidth !== oldWidth) {
    for (const [n, change] of renumberFollowing(
      state,
      block.to,
      line.number,
      oldWidth,
      oldStart,
      unit,
    )) {
      if (!changes.has(n)) changes.set(n, change);
    }
  }

  // Keep the caret on the same body character; one in the indent or marker
  // lands at the body start.
  const bodyStart =
    line.from +
    item.indent.length +
    String(item.num).length +
    item.delim.length +
    item.gap.length;
  const offset = Math.max(0, pos - bodyStart);
  const newBodyStart =
    line.from + newIndent.length + String(newNum).length + item.delim.length + item.gap.length;

  view.dispatch({
    changes: [...changes.entries()].sort((a, b) => a[0] - b[0]).map(([, c]) => c),
    selection: EditorSelection.cursor(newBodyStart + offset),
    userEvent: dir === 1 ? 'input.indent' : 'delete.dedent',
    scrollIntoView: true,
  });
  return true;
}

export function mdListIndentKeymap(
  isInMathContext: (state: EditorState, pos: number) => boolean,
): Extension {
  // setup.ts registers this after hsnips / autocomplete / Tabout and before
  // `indentWithTab`, so snippet tabstops and the completion popup own Tab.
  return keymap.of([
    {
      key: 'Tab',
      run: (view: EditorView) => mdOrderedIndentRun(view, isInMathContext, 1),
    },
    {
      key: 'Shift-Tab',
      run: (view: EditorView) => mdOrderedIndentRun(view, isInMathContext, -1),
    },
  ]);
}
