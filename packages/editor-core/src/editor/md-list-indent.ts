import { ChangeSpec, EditorSelection, Extension } from '@codemirror/state';
import { indentUnit } from '@codemirror/language';
import { EditorView, keymap } from '@codemirror/view';
import {
  indentWidth,
  keepFolds,
  leadingWhitespace,
  listBlockBounds,
  outlineNodeAt,
  precedingSiblingNumber,
  renumberFollowing,
  shiftIndent,
  type MathContext,
} from './md-outline-tree';

/**
 * Tab / Shift+Tab on a Markdown list item: the item moves one level with its
 * whole subtree (children and continuation lines), the outliner rule. An
 * ordered item is renumbered after the nearest sibling at its new depth (1 if
 * none), and the run it left is renumbered so it stays contiguous:
 *
 *     1. a          Tab on b      1. a
 *     2. b          ──────────→       1. b
 *     3. c                        2. c
 *
 * Only a list item with an empty selection outside math and code is claimed;
 * everything else falls through to `indentWithTab`. Policy table:
 * docs/specs/2026-11-07-markdown-outliner.md.
 */
export function mdListIndentRun(
  view: EditorView,
  isInMathContext: MathContext,
  dir: 1 | -1,
): boolean {
  const { state } = view;
  const sel = state.selection.main;
  if (!sel.empty) return false;
  const pos = sel.head;
  if (isInMathContext(state, pos)) return false;

  const line = state.doc.lineAt(pos);
  const node = outlineNodeAt(state, line.number);
  const item = node?.item;
  if (!node || !item) return false;

  const unit = state.facet(indentUnit);
  const newIndent = shiftIndent(item.indent, unit, dir);
  if (newIndent === null) return false;

  const oldWidth = indentWidth(item.indent, unit);
  const newWidth = indentWidth(newIndent, unit);
  const subtreeEnd = node.end;

  // The head line: indent, and for an ordered item its new number.
  let newMarker = item.marker;
  const changes = new Map<number, ChangeSpec>();
  if (item.kind === 'ordered') {
    const block = listBlockBounds(state, line.number, unit);
    const newNum = precedingSiblingNumber(state, block.from, line.number, newWidth, unit) + 1;
    newMarker = `${newNum}${item.delim}`;
    // The run the item joins, then the run it left, each numbered from what
    // sits above it, so a middle item's departure closes the gap. Both scans
    // start below the subtree: its children move with it.
    const oldStart = precedingSiblingNumber(state, block.from, line.number, oldWidth, unit) + 1;
    for (const [n, c] of renumberFollowing(state, block.to, subtreeEnd, newWidth, newNum + 1, unit)) {
      changes.set(n, c);
    }
    if (newWidth !== oldWidth) {
      for (const [n, c] of renumberFollowing(state, block.to, subtreeEnd, oldWidth, oldStart, unit)) {
        if (!changes.has(n)) changes.set(n, c);
      }
    }
  }
  changes.set(line.number, {
    from: line.from,
    to: line.from + item.indent.length + item.marker.length,
    insert: newIndent + newMarker,
  });

  // The subtree moves with its head, blank lines untouched.
  for (let n = line.number + 1; n <= subtreeEnd; n++) {
    const child = state.doc.line(n);
    if (child.text.trim().length === 0) continue;
    const lead = leadingWhitespace(child.text);
    const shifted = shiftIndent(lead, unit, dir) ?? '';
    changes.set(n, { from: child.from, to: child.from + lead.length, insert: shifted });
  }

  // Keep the caret on the same body character; one in the indent or marker
  // lands at the body start.
  const bodyStart = line.from + item.bodyOffset;
  const offset = Math.max(0, pos - bodyStart);
  const newBodyStart =
    bodyStart + (newIndent.length - item.indent.length) + (newMarker.length - item.marker.length);

  const changeSet = state.changes(
    [...changes.entries()].sort((a, b) => a[0] - b[0]).map(([, c]) => c),
  );
  view.dispatch({
    changes: changeSet,
    selection: EditorSelection.cursor(newBodyStart + offset),
    // A folded subtree stays folded as it moves.
    effects: keepFolds(state, changeSet),
    userEvent: dir === 1 ? 'input.indent' : 'delete.dedent',
    scrollIntoView: true,
  });
  return true;
}

export function mdListIndentKeymap(isInMathContext: MathContext): Extension {
  // setup.ts registers this after hsnips / autocomplete / Tabout and before
  // `indentWithTab`, so snippet tabstops and the completion popup own Tab.
  return keymap.of([
    {
      key: 'Tab',
      run: (view: EditorView) => mdListIndentRun(view, isInMathContext, 1),
    },
    {
      key: 'Shift-Tab',
      run: (view: EditorView) => mdListIndentRun(view, isInMathContext, -1),
    },
  ]);
}
