import { foldEffect, foldedRanges, indentUnit } from '@codemirror/language';
import {
  EditorSelection,
  Prec,
  type ChangeSpec,
  type EditorState,
  type Extension,
  type StateEffect,
} from '@codemirror/state';
import { keymap, type Command } from '@codemirror/view';
import { mdListIndentRun } from './md-list-indent';
import { foldOnLine } from './md-fold';
import {
  ATX_MARK_RE,
  indentWidth,
  inCodeOrFrontmatter,
  keepFolds,
  leadingWhitespace,
  listBlockBounds,
  listItemAt,
  nextSibling,
  outlineNodeAt,
  parseListLine,
  prevSibling,
  renumberFollowing,
  siblingPrefix,
  type ListLine,
  type MathContext,
  type OutlineNode,
} from './md-outline-tree';

/**
 * Outliner keys for Markdown. Every structural command moves a list item or
 * heading together with its subtree (md-outline-tree.ts). Each handler claims
 * only its own construct and returns false otherwise, so the stock command
 * still runs on plain text. Policy table, one row per key and construct:
 * docs/specs/2026-11-07-markdown-outliner.md.
 */

function caretLine(state: EditorState) {
  return state.doc.lineAt(state.selection.main.head);
}

/** Renumber the ordered run at `item`'s depth below line `after`, from `start`. */
function renumberRun(
  state: EditorState,
  lineNo: number,
  item: ListLine,
  after: number,
  start: number,
): ChangeSpec[] {
  const unit = state.facet(indentUnit);
  const block = listBlockBounds(state, lineNo, unit);
  return [...renumberFollowing(state, block.to, after, indentWidth(item.indent, unit), start, unit).values()];
}

// --- Enter on a folded head row -------------------------------------------------

/**
 * Enter at the end of a folded item or heading: the new line goes after the
 * hidden subtree, so the children stay with their parent. A list item gets a
 * sibling marker (`siblingPrefix`); a heading gets a plain line.
 */
const enterAfterFold =
  (isInMath: MathContext): Command =>
  (view) => {
    const { state } = view;
    const sel = state.selection.main;
    if (!sel.empty || isInMath(state, sel.head)) return false;
    const line = state.doc.lineAt(sel.head);
    const fold = foldOnLine(state, line.number);
    if (!fold || sel.head !== line.to) return false;
    const item = listItemAt(state, line.number);
    const insert = item ? `\n${siblingPrefix(item)}` : '\n';
    const changes: ChangeSpec[] =
      item?.kind === 'ordered'
        ? renumberRun(state, line.number, item, state.doc.lineAt(fold.to).number, item.num + 2)
        : [];
    changes.push({ from: fold.to, insert });
    view.dispatch({
      changes,
      selection: EditorSelection.cursor(fold.to + insert.length),
      userEvent: 'input',
      scrollIntoView: true,
    });
    return true;
  };

// --- Move subtree up / down -----------------------------------------------------

/** The node whose head the caret is on (a Setext heading spans two lines). */
function nodeAtCaret(state: EditorState): OutlineNode | null {
  const n = caretLine(state).number;
  for (let l = n; l >= Math.max(1, n - 1); l--) {
    const node = outlineNodeAt(state, l);
    if (node && n >= node.line && n <= node.headEnd) return node;
  }
  return null;
}

/** `text`'s first line, an ordered head, takes number `num`. */
function withNumber(text: string, num: number): string {
  const nl = text.indexOf('\n');
  const item = parseListLine(nl < 0 ? text : text.slice(0, nl));
  if (item?.kind !== 'ordered') return text;
  const at = item.indent.length;
  return text.slice(0, at) + String(num) + text.slice(at + String(item.num).length);
}

/**
 * Alt-Up / Alt-Down on a head line: swap the subtree with its previous / next
 * sibling. At the first or last sibling the key is claimed and nothing moves
 * (the stock line move would tear the item out of its parent). Two ordered
 * siblings keep their positions' numbers. The swap is one replace, which
 * collapses the folds inside it, so they are re-added at their new offsets.
 */
function moveSubtree(dir: -1 | 1): Command {
  return (view) => {
    const { state } = view;
    const sel = state.selection.main;
    if (!sel.empty) return false;
    const node = nodeAtCaret(state);
    if (!node) return false;
    const sib = dir < 0 ? prevSibling(state, node) : nextSibling(state, node);
    if (!sib) return true;
    const [a, b] = dir < 0 ? [sib, node] : [node, sib];
    const doc = state.doc;
    const aFrom = doc.line(a.line).from;
    const aTo = doc.line(a.end).to;
    const bFrom = doc.line(b.line).from;
    const bTo = doc.line(b.end).to;
    let aText = doc.sliceString(aFrom, aTo);
    let bText = doc.sliceString(bFrom, bTo);
    if (a.item?.kind === 'ordered' && b.item?.kind === 'ordered') {
      aText = withNumber(aText, b.item.num);
      bText = withNumber(bText, a.item.num);
    }
    const gap = doc.sliceString(aTo, bFrom);
    // Old A lands after B + gap; old B lands at A's start. A renumbered head
    // shifts what follows it in its own block by the digit-count change.
    const aShift = bText.length + gap.length + aText.length - (aTo - aFrom);
    const bShift = aFrom - bFrom + bText.length - (bTo - bFrom);
    const effects: StateEffect<unknown>[] = [];
    foldedRanges(state).between(aFrom, bTo, (from, to) => {
      const shift = from >= aFrom && to <= aTo ? aShift : from >= bFrom && to <= bTo ? bShift : null;
      if (shift !== null) effects.push(foldEffect.of({ from: from + shift, to: to + shift }));
    });
    const movingStart = node === a ? aFrom + bText.length + gap.length : aFrom;
    const movingText = node === a ? aText : bText;
    const head = movingStart + Math.min(sel.head - doc.line(node.line).from, movingText.length);
    view.dispatch({
      changes: { from: aFrom, to: bTo, insert: bText + gap + aText },
      selection: EditorSelection.cursor(head),
      effects,
      userEvent: 'move.line',
      scrollIntoView: true,
    });
    return true;
  };
}

// --- Heading Tab / Shift-Tab ---------------------------------------------------------

/**
 * Tab / Shift-Tab on an ATX heading line: demote / promote the heading and
 * every heading in its section, so the outline below keeps its shape. Claimed
 * but a no-op when any level would leave 1–6. Setext headings fall through.
 */
const shiftHeading =
  (isInMath: MathContext, dir: 1 | -1): Command =>
  (view) => {
    const { state } = view;
    const sel = state.selection.main;
    if (!sel.empty || isInMath(state, sel.head)) return false;
    const node = outlineNodeAt(state, caretLine(state).number);
    if (node?.kind !== 'heading' || node.headEnd !== node.line) return false;
    const changes: ChangeSpec[] = [];
    for (let n = node.line; n <= node.end; n++) {
      const h = outlineNodeAt(state, n);
      if (h?.kind !== 'heading' || h.headEnd !== n) continue; // Setext stays
      const level = h.level + dir;
      if (level < 1 || level > 6) return true;
      const line = state.doc.line(n);
      const from = line.from + leadingWhitespace(line.text).length;
      changes.push(dir > 0 ? { from, insert: '#' } : { from, to: from + 1 });
    }
    const changeSet = state.changes(changes);
    view.dispatch({
      changes: changeSet,
      effects: keepFolds(state, changeSet),
      userEvent: dir > 0 ? 'input.indent' : 'delete.dedent',
      scrollIntoView: true,
    });
    return true;
  };

// --- Backspace at an item's body start --------------------------------------------

/**
 * Backspace with the caret right after a list marker peels one layer: a nested
 * item outdents (with its subtree), a top-level task loses its box, a
 * top-level item loses its marker (and an ordered run closes the gap).
 */
const backspaceItem =
  (isInMath: MathContext): Command =>
  (view) => {
    const { state } = view;
    const sel = state.selection.main;
    if (!sel.empty) return false;
    const line = caretLine(state);
    const item = listItemAt(state, line.number);
    if (!item || sel.head !== line.from + item.bodyOffset) return false;
    if (item.indent.length > 0) return mdListIndentRun(view, isInMath, -1);
    const boxFrom = line.from + item.bodyOffset - item.box.length;
    const changes: ChangeSpec[] = item.box
      ? [{ from: boxFrom, to: sel.head }]
      : [
          { from: line.from, to: boxFrom },
          ...(item.kind === 'ordered' ? renumberRun(state, line.number, item, line.number, item.num) : []),
        ];
    view.dispatch({
      changes,
      selection: EditorSelection.cursor(item.box ? boxFrom : line.from),
      userEvent: 'delete.backward.marker',
    });
    return true;
  };

// --- Checkboxes and list type --------------------------------------------------------

/** Lines touched by the main selection, skipping blank lines, code and frontmatter. */
function selectedLines(state: EditorState): number[] {
  const { from, to } = state.selection.main;
  const first = state.doc.lineAt(from).number;
  const last = state.doc.lineAt(to).number;
  const out: number[] = [];
  for (let n = first; n <= last; n++) {
    const line = state.doc.line(n);
    if (line.text.trim().length === 0) continue;
    if (inCodeOrFrontmatter(state, line.from)) continue;
    out.push(n);
  }
  return out;
}

/**
 * Mod-Enter on list items steps a checkbox: no box → `[ ]` → `[x]` → `[ ]`.
 * The first selected item decides the step for all of them: boxless items get
 * `[ ] `, or every box is ticked, or every box is unticked. Falls through
 * (stock `insertBlankLine`) when no selected line is an item.
 */
const toggleTask: Command = (view) => {
  const { state } = view;
  const items = selectedLines(state).flatMap((n) => {
    const item = listItemAt(state, n);
    return item ? [{ n, item }] : [];
  });
  if (!items.length) return false;
  const first = items[0].item.box;
  const step = !first ? 'add' : /^\[[xX]\]/.test(first) ? 'untick' : 'tick';
  const changes: ChangeSpec[] = [];
  for (const { n, item } of items) {
    const boxAt = state.doc.line(n).from + item.bodyOffset - item.box.length;
    if (step === 'add') {
      if (!item.box) changes.push({ from: boxAt, insert: '[ ] ' });
    } else if (item.box) {
      changes.push({ from: boxAt + 1, to: boxAt + 2, insert: step === 'tick' ? 'x' : ' ' });
    }
  }
  view.dispatch({ changes, userEvent: 'input.toggle', scrollIntoView: true });
  return true;
};

type ListType = 'bullet' | 'ordered' | 'task';

function typeOf(item: ListLine | null): ListType | null {
  if (!item) return null;
  return item.box ? 'task' : item.kind;
}

/**
 * Mod-Shift-8 / 7 / 9: make the selected lines bullets, a numbered list or
 * tasks. When every selected line already is that type, they go back to plain
 * paragraphs. Headings lose their `#`s. Numbers count from 1 per indent level
 * inside the selection.
 */
function setListType(target: ListType): Command {
  return (view) => {
    const { state } = view;
    const lines = selectedLines(state).map((n) => ({ n, item: listItemAt(state, n) }));
    if (!lines.length) return false;
    const unit = state.facet(indentUnit);
    const remove = lines.every(({ item }) => typeOf(item) === target);
    const counters = new Map<number, number>();
    const changes: ChangeSpec[] = [];
    for (const { n, item } of lines) {
      const line = state.doc.line(n);
      const indent = item ? item.indent : leadingWhitespace(line.text);
      let bodyOffset = item ? item.bodyOffset : indent.length;
      if (!item && outlineNodeAt(state, n)?.kind === 'heading') {
        bodyOffset = ATX_MARK_RE.exec(line.text)?.[0].length ?? bodyOffset;
      }
      let marker = '';
      if (!remove && target === 'ordered') {
        const w = indentWidth(indent, unit);
        for (const k of [...counters.keys()]) if (k > w) counters.delete(k);
        const num = (counters.get(w) ?? 0) + 1;
        counters.set(w, num);
        marker = `${num}. `;
      } else if (!remove) {
        marker = target === 'task' ? '- [ ] ' : '- ';
      }
      changes.push({ from: line.from, to: line.from + bodyOffset, insert: indent + marker });
    }
    view.dispatch({ changes, userEvent: 'input.list', scrollIntoView: true });
    return true;
  };
}

// --- Wiring -------------------------------------------------------------------------

/** Above markdown()'s Prec.high Enter / Backspace and the tight-bullet Enter. */
export function mdOutlinerPriorityKeymap(isInMath: MathContext): Extension {
  return Prec.highest(
    keymap.of([
      { key: 'Enter', run: enterAfterFold(isInMath) },
      { key: 'Backspace', run: backspaceItem(isInMath) },
    ]),
  );
}

/** Structural keys, Prec.high so they beat `defaultKeymap`'s line moves and
 *  `insertBlankLine` wherever setup.ts lists them. */
export function mdOutlinerKeymap(): Extension {
  return Prec.high(
    keymap.of([
      { key: 'Alt-ArrowUp', run: moveSubtree(-1) },
      { key: 'Alt-ArrowDown', run: moveSubtree(1) },
      { key: 'Mod-Enter', run: toggleTask },
      { key: 'Mod-Shift-8', run: setListType('bullet') },
      { key: 'Mod-Shift-7', run: setListType('ordered') },
      { key: 'Mod-Shift-9', run: setListType('task') },
    ]),
  );
}

/** Tab / Shift-Tab on headings; setup.ts puts it beside mdListIndentKeymap
 *  (after hsnips, completion and tabout, before indentWithTab). */
export function mdHeadingIndentKeymap(isInMath: MathContext): Extension {
  return keymap.of([
    { key: 'Tab', run: shiftHeading(isInMath, 1) },
    { key: 'Shift-Tab', run: shiftHeading(isInMath, -1) },
  ]);
}
