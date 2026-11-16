import { Extension, Prec } from '@codemirror/state';
import { EditorView, keymap } from '@codemirror/view';
import { listItemAt, siblingPrefix, type MathContext } from './md-outline-tree';

/**
 * Tight Enter for Markdown bullet lists. `markdown()`'s
 * `insertNewlineContinueMarkup` keeps a loose list loose, inserting a blank
 * line before every new marker; Enter after `- foo` should give `- ` on the
 * next line. A non-empty item continues tightly (a task item gets a fresh
 * `[ ] `); an empty item exits the list. Everything else, including a `- `
 * line in code or frontmatter, falls through to the default command.
 */

function mdBulletEnterRun(view: EditorView, isInMathContext: MathContext): boolean {
  const { state } = view;
  const sel = state.selection.main;
  if (!sel.empty) return false;
  const pos = sel.head;
  if (isInMathContext(state, pos)) return false;

  const line = state.doc.lineAt(pos);
  const item = listItemAt(state, line.number);
  if (item?.kind !== 'bullet') return false;
  const body = line.text.slice(item.bodyOffset);

  // Empty item: clear the line to exit the list (the default would keep the
  // bullet and insert a blank line).
  if (body.trim().length === 0) {
    view.dispatch({
      changes: { from: line.from, to: line.to, insert: '' },
      selection: { anchor: line.from },
      userEvent: 'delete',
      scrollIntoView: true,
    });
    return true;
  }

  if (pos < line.from + item.bodyOffset) return false;

  // Mid-line Enter splits the item, like the default minus the blank line.
  const insert = `\n${siblingPrefix(item)}`;
  view.dispatch({
    changes: { from: pos, to: pos, insert },
    selection: { anchor: pos + insert.length },
    userEvent: 'input',
    scrollIntoView: true,
  });
  return true;
}

export function mdListNewlineKeymap(isInMathContext: MathContext): Extension {
  // Above markdown()'s own Enter binding, which is Prec.high.
  return Prec.highest(
    keymap.of([
      {
        key: 'Enter',
        run: (view: EditorView) => mdBulletEnterRun(view, isInMathContext),
      },
    ]),
  );
}
