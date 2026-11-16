import { foldEffect, foldedRanges, indentUnit, syntaxTree } from '@codemirror/language';
import type { ChangeSet, ChangeSpec, EditorState, StateEffect, Text } from '@codemirror/state';
import { scanCallouts } from './md-callout-plugin';

/**
 * The Markdown outline as the outliner commands see it: list items and ATX /
 * Setext headings, each with a subtree. Folding, subtree moves, Tab, guides and
 * zoom all ask `outlineNodeAt` / `ancestorsAt`, so they agree on what "the item
 * and its children" covers. Policy table: docs/specs/2026-11-07-markdown-outliner.md.
 *
 * A list item's subtree is walked by indentation: a deeper line continues it,
 * a blank line continues it only when a deeper line follows. A heading's
 * section runs to the last top-level node before the next heading of the same
 * or a higher level, so trailing blank lines stay outside it (lang-markdown's
 * `findSectionEnd`).
 */

/** The `isInMathContext` callback every Markdown key handler takes. */
export type MathContext = (state: EditorState, pos: number) => boolean;

// indent | bullet | gap | body. Whitespace after the marker is required, so
// `-foo`, `*emphasis*` and `***` don't match.
const MD_BULLET_RE = /^([ \t]*)([-*+])([ \t]+)(.*)$/;
// indent | number | delimiter | gap | body.
const MD_ORDERED_RE = /^([ \t]*)(\d+)([.)])([ \t]+)(.*)$/;
const TASK_BOX_RE = /^\[[ xX]\](?:[ \t]+|$)/;
/** An ATX heading's marks with the space after them: `## `. */
export const ATX_MARK_RE = /^ {0,3}#{1,6}(?:[ \t]+|$)/;

// Lezer's code and frontmatter nodes. Narrower than md-math-plugin's
// `isInCodeMd`, which also counts inline code: a list marker can't be inside
// one, but it can sit in a frontmatter block.
const NOT_A_LIST = new Set(['FencedCode', 'CodeBlock', 'Frontmatter']);

/** True inside fenced or indented code, or the frontmatter block. */
export function inCodeOrFrontmatter(state: EditorState, pos: number): boolean {
  const tree = syntaxTree(state);
  let node: ReturnType<typeof tree.resolveInner> | null = tree.resolveInner(pos, -1);
  for (; node; node = node.parent) if (NOT_A_LIST.has(node.name)) return true;
  return false;
}

export function leadingWhitespace(text: string): string {
  const m = text.match(/^[ \t]*/);
  return m ? m[0] : '';
}

/** Indent in columns, a tab counting as one whole indent unit. */
export function indentWidth(indent: string, unit: string): number {
  let w = 0;
  for (const c of indent) w += c === '\t' ? unit.length : 1;
  return w;
}

/** One list-item line split into its parts. Offsets are from the line start. */
interface ListLineBase {
  indent: string;
  /** `-`, `*`, `+`, or `12.` / `12)`. */
  marker: string;
  gap: string;
  /** `[ ] ` / `[x]` with its trailing space, or `''`. */
  box: string;
  /** Offset of the body (after indent, marker, gap and box). */
  bodyOffset: number;
}
export type ListLine =
  | (ListLineBase & { kind: 'bullet' })
  | (ListLineBase & { kind: 'ordered'; num: number; delim: string });

export function parseListLine(text: string): ListLine | null {
  const o = text.match(MD_ORDERED_RE);
  const m = o ?? text.match(MD_BULLET_RE);
  if (!m) return null;
  const indent = m[1];
  const marker = o ? o[2] + o[3] : m[2];
  const gap = o ? o[4] : m[3];
  const box = (o ? o[5] : m[4]).match(TASK_BOX_RE)?.[0] ?? '';
  const base = {
    indent,
    marker,
    gap,
    box,
    bodyOffset: indent.length + marker.length + gap.length + box.length,
  };
  return o
    ? { ...base, kind: 'ordered', num: parseInt(o[2], 10), delim: o[3] }
    : { ...base, kind: 'bullet' };
}

/** The list item on line `lineNo`, or null (not a list line, or in code). */
export function listItemAt(state: EditorState, lineNo: number): ListLine | null {
  const line = state.doc.line(lineNo);
  const item = parseListLine(line.text);
  if (!item) return null;
  if (inCodeOrFrontmatter(state, line.from + item.indent.length)) return null;
  return item;
}

/** What a new sibling of `item` starts with: the same indent and marker (the
 *  next number for an ordered item) and a fresh `[ ] ` for a task. */
export function siblingPrefix(item: ListLine): string {
  const marker = item.kind === 'ordered' ? `${item.num + 1}${item.delim}` : item.marker;
  return `${item.indent}${marker} ${item.box ? '[ ] ' : ''}`;
}

function lineWidth(state: EditorState, lineNo: number, unit: string): number {
  return indentWidth(leadingWhitespace(state.doc.line(lineNo).text), unit);
}

function isBlank(state: EditorState, lineNo: number): boolean {
  return state.doc.line(lineNo).text.trim().length === 0;
}

// Two rules Markdown doesn't settle, shared by the list-block helpers below:
//  - A list block is walked line by line: list items continue it, and so does
//    a non-list line deeper than the last item (a continuation). A blank line
//    or a paragraph at or left of that indent ends it.
//  - A bullet at the same depth ends an ordered sibling run and is never
//    renumbered.

/** First and last line number (inclusive) of the list block holding `lineNo`. */
export function listBlockBounds(
  state: EditorState,
  lineNo: number,
  unit: string,
): { from: number; to: number } {
  const scan = (dir: -1 | 1): number => {
    let last = lineNo;
    let itemWidth = lineWidth(state, lineNo, unit);
    for (let n = lineNo + dir; n >= 1 && n <= state.doc.lines; n += dir) {
      const text = state.doc.line(n).text;
      if (text.trim().length === 0) break;
      const w = lineWidth(state, n, unit);
      if (parseListLine(text)) itemWidth = w;
      else if (w <= itemWidth) break;
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
export function precedingSiblingNumber(
  state: EditorState,
  blockFrom: number,
  lineNo: number,
  targetWidth: number,
  unit: string,
): number {
  for (let n = lineNo - 1; n >= blockFrom; n--) {
    const item = parseListLine(state.doc.line(n).text);
    if (!item) continue; // continuation line
    const w = indentWidth(item.indent, unit);
    if (w > targetWidth) continue;
    if (w < targetWidth || item.kind === 'bullet') return 0;
    return item.num;
  }
  return 0;
}

/**
 * Renumber the ordered siblings below `lineNo` at `targetWidth` from `start`.
 * Keyed by line number so two passes (new depth, old depth) can't collide.
 */
export function renumberFollowing(
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
    const item = parseListLine(line.text);
    if (!item) continue; // continuation line
    const w = indentWidth(item.indent, unit);
    if (w > targetWidth) continue;
    if (w < targetWidth || item.kind === 'bullet') break;
    if (item.num !== next) {
      const from = line.from + item.indent.length;
      out.set(n, { from, to: from + String(item.num).length, insert: String(next) });
    }
    next++;
  }
  return out;
}

/** Indent for one step in `dir`, or null when a dedent has nothing to remove. */
export function shiftIndent(indent: string, unit: string, dir: 1 | -1): string | null {
  if (dir === 1) return indent + unit;
  if (indent.length === 0) return null;
  // Trim from the END so a leading tab survives a space-unit dedent.
  if (indent.endsWith(unit)) return indent.slice(0, indent.length - unit.length);
  if (indent.endsWith('\t')) return indent.slice(0, -1);
  return indent.slice(0, Math.max(0, indent.length - unit.length));
}

/**
 * Folds that a command editing `changes` would otherwise lose, as effects for
 * the same transaction: foldState drops every fold a `delete` event touches,
 * and effects apply after that, so the folds come back under any label.
 */
export function keepFolds(state: EditorState, changes: ChangeSet): StateEffect<unknown>[] {
  const out: StateEffect<unknown>[] = [];
  const folds = foldedRanges(state);
  changes.iterChangedRanges((fromA, toA) => {
    folds.between(fromA, toA, (from, to) => {
      if (from >= toA || to <= fromA) return;
      const a = changes.mapPos(from, 1);
      const b = changes.mapPos(to, -1);
      if (b > a) out.push(foldEffect.of({ from: a, to: b }));
    });
  });
  return out;
}

// --- Nodes -----------------------------------------------------------------------

/** Outline node on a line: what the outliner commands act on. */
export interface OutlineNode {
  kind: 'item' | 'heading';
  /** First line (the marker or heading line). */
  line: number;
  /** Last line of the head (Setext underline); == line for items and ATX. */
  headEnd: number;
  /** Last line of the subtree or section, no trailing blank lines. */
  end: number;
  /** Heading level, or the item's indent width in columns. */
  level: number;
  item?: ListLine;
}

function headingLevelOfNode(name: string): number {
  const m = /^(?:ATX|Setext)Heading(\d)$/.exec(name);
  return m ? Number(m[1]) : 0;
}

/** The top-level syntax node holding `pos` (or the next one), via Lezer's
 *  balanced tree rather than a walk from the first child. */
function topNodeAt(state: EditorState, pos: number) {
  return syntaxTree(state).topNode.childAfter(pos);
}

/**
 * Level and last line of a top-level heading on `lineNo` (its Setext
 * underline). Null for no heading, or one nested in a list, quote or callout
 * title, which has no section.
 */
function headingAt(state: EditorState, lineNo: number): { level: number; endLine: number } | null {
  const line = state.doc.line(lineNo);
  // Cheap pre-check: an ATX `#` or a next-line Setext underline.
  const next = lineNo < state.doc.lines ? state.doc.line(lineNo + 1).text : '';
  if (!ATX_MARK_RE.test(line.text) && !/^ {0,3}(=+|-+)[ \t]*$/.test(next)) return null;
  const node = topNodeAt(state, line.from);
  if (!node || state.doc.lineAt(node.from).number !== lineNo) return null;
  const level = headingLevelOfNode(node.name);
  if (!level) return null;
  if (scanCallouts(state.doc).some((r) => r.titleLine === lineNo)) return null;
  return { level, endLine: state.doc.lineAt(node.to).number };
}

/** Raw section end (the clamps are `clampEnd`'s job). */
function headingSectionEnd(state: EditorState, lineNo: number, level: number): number {
  const head = topNodeAt(state, state.doc.line(lineNo).from);
  if (!head) return lineNo;
  let lastTo = head.to;
  for (let node = head.nextSibling; node; node = node.nextSibling) {
    const lv = headingLevelOfNode(node.name);
    if (lv && lv <= level) break;
    lastTo = node.to;
  }
  return state.doc.lineAt(lastTo).number;
}

/** Raw item subtree end: deeper lines and the blank lines between them. */
function itemSubtreeEnd(state: EditorState, lineNo: number): number {
  const unit = state.facet(indentUnit);
  const w = lineWidth(state, lineNo, unit);
  let last = lineNo;
  for (let n = lineNo + 1; n <= state.doc.lines; n++) {
    if (isBlank(state, n)) continue;
    if (lineWidth(state, n, unit) <= w) break;
    last = n;
  }
  return last;
}

// Blocks a subtree may not end inside (spec section 1).
const WHOLE_BLOCKS = new Set(['DisplayMath', 'FencedCode', 'CodeBlock', 'Table']);

/**
 * Never end a subtree strictly inside a callout or a block (display math,
 * code, table) that starts inside it: extend to that construct's last line,
 * so a fold never leaves half a box or a block widget's tail. A node inside a
 * callout ends at the callout's last body line.
 */
function clampEnd(state: EditorState, startLine: number, end: number): number {
  const callouts = scanCallouts(state.doc);
  let out = end;
  for (const r of callouts) {
    if (r.openLine > startLine && r.openLine <= out && r.closeLine > out) out = r.closeLine;
  }
  const endPos = state.doc.line(out).to;
  const node = topNodeAt(state, endPos);
  if (
    node &&
    WHOLE_BLOCKS.has(node.name) &&
    node.from < endPos &&
    node.from > state.doc.line(startLine).to
  ) {
    out = Math.max(out, state.doc.lineAt(node.to).number);
  }
  // Lezer reads a `:::` fence as paragraph text, so a section can run past
  // the close of a callout holding its start: cap it there.
  const box = callouts.find((r) => r.openLine < startLine && startLine < r.closeLine);
  if (box && out >= box.closeLine) {
    out = box.closeLine - 1;
    while (out > startLine && isBlank(state, out)) out--;
  }
  return out;
}

function computeNode(state: EditorState, lineNo: number): OutlineNode | null {
  const item = listItemAt(state, lineNo);
  if (item) {
    return {
      kind: 'item',
      line: lineNo,
      headEnd: lineNo,
      end: clampEnd(state, lineNo, itemSubtreeEnd(state, lineNo)),
      level: indentWidth(item.indent, state.facet(indentUnit)),
      item,
    };
  }
  const h = headingAt(state, lineNo);
  if (!h) return null;
  const end = clampEnd(state, lineNo, headingSectionEnd(state, lineNo, h.level));
  return { kind: 'heading', line: lineNo, headEnd: h.endLine, end: Math.max(end, h.endLine), level: h.level };
}

// Per (doc, tree), filled on demand: the guides, the chevron hover and the
// fold and zoom commands ask the same lines over and over between edits. A
// tree that is still parsing gives different answers, hence the tree key.
const nodeCache = new WeakMap<Text, { tree: unknown; nodes: Map<number, OutlineNode | null> }>();

export function outlineNodeAt(state: EditorState, lineNo: number): OutlineNode | null {
  const tree = syntaxTree(state);
  let hit = nodeCache.get(state.doc);
  if (!hit || hit.tree !== tree) {
    hit = { tree, nodes: new Map() };
    nodeCache.set(state.doc, hit);
  }
  let node = hit.nodes.get(lineNo);
  if (node === undefined) {
    node = computeNode(state, lineNo);
    hit.nodes.set(lineNo, node);
  }
  return node;
}

/**
 * Nodes whose subtree holds `lineNo`, outermost first: enclosing headings by
 * walking back over top-level nodes, enclosing items by walking up to ever
 * shallower lines. O(depth) node lookups, not O(lines).
 */
export function ancestorsAt(state: EditorState, lineNo: number): OutlineNode[] {
  const unit = state.facet(indentUnit);
  const items: OutlineNode[] = [];
  const self = outlineNodeAt(state, lineNo);
  if (self) items.push(self);
  let minW = isBlank(state, lineNo) ? Infinity : lineWidth(state, lineNo, unit);
  for (let n = lineNo - 1; n >= 1 && minW > 0; n--) {
    if (isBlank(state, n)) continue;
    const w = lineWidth(state, n, unit);
    if (w >= minW) continue;
    const node = outlineNodeAt(state, n);
    if (node?.kind === 'item') {
      if (node.end >= lineNo) items.unshift(node);
      minW = w;
    } else if (w === 0) {
      break; // a top-level paragraph ends the list
    }
  }
  const headings: OutlineNode[] = [];
  const line = state.doc.line(lineNo);
  let top = syntaxTree(state).topNode.childBefore(line.from + 1);
  let minLevel = self?.kind === 'heading' ? self.level : 7;
  if (self?.kind === 'heading' && top) top = top.prevSibling;
  for (; top && minLevel > 1; top = top.prevSibling) {
    const lv = headingLevelOfNode(top.name);
    if (!lv || lv >= minLevel) continue;
    const node = outlineNodeAt(state, state.doc.lineAt(top.from).number);
    if (node && node.end >= lineNo) headings.unshift(node);
    minLevel = lv;
  }
  return [...headings, ...items];
}

/**
 * Previous sibling of `node`: the nearest node above at the same level, with no
 * shallower item (or same-or-higher heading) in between.
 */
export function prevSibling(state: EditorState, node: OutlineNode): OutlineNode | null {
  if (node.kind === 'item') {
    const unit = state.facet(indentUnit);
    for (let n = node.line - 1; n >= 1; n--) {
      if (isBlank(state, n)) continue;
      const w = lineWidth(state, n, unit);
      if (w > node.level) continue;
      if (w < node.level) return null;
      const sib = outlineNodeAt(state, n);
      return sib && sib.kind === 'item' ? sib : null;
    }
    return null;
  }
  for (let top = topNodeAt(state, state.doc.line(node.line).from)?.prevSibling; top; top = top.prevSibling) {
    const lv = headingLevelOfNode(top.name);
    if (!lv || lv > node.level) continue;
    if (lv < node.level) return null;
    return outlineNodeAt(state, state.doc.lineAt(top.from).number);
  }
  return null;
}

export function nextSibling(state: EditorState, node: OutlineNode): OutlineNode | null {
  for (let n = node.end + 1; n <= state.doc.lines; n++) {
    if (isBlank(state, n)) continue;
    // The first non-blank line after a subtree is a sibling or nothing: a
    // section absorbs body text, and an item's subtree absorbs deeper lines.
    const sib = outlineNodeAt(state, n);
    return sib && sib.kind === node.kind && sib.level === node.level ? sib : null;
  }
  return null;
}

/** Every outline node whose subtree spans more than its head, in doc order. */
export function foldableNodes(state: EditorState): OutlineNode[] {
  const out: OutlineNode[] = [];
  for (let n = 1; n <= state.doc.lines; n++) {
    const node = outlineNodeAt(state, n);
    if (node && node.end > node.headEnd) out.push(node);
  }
  return out;
}
