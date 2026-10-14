import { syntaxTree } from '@codemirror/language';
import { EditorState, Extension, Prec } from '@codemirror/state';
import { EditorView, keymap } from '@codemirror/view';

/**
 * Tight Enter for Markdown bullet lists. `markdown()`'s
 * `insertNewlineContinueMarkup` keeps a loose list loose, inserting a blank
 * line before every new marker; Enter after `- foo` should give `- ` on the
 * next line. A non-empty item continues tightly (a task item gets a fresh
 * `[ ] `); an empty item exits the list. Everything else, including a `- `
 * line in code or frontmatter, falls through to the default command.
 */

// indent | bullet | gap | body. Whitespace after the marker is required, so
// `-foo`, `*emphasis*` and `***` don't match.
export const MD_BULLET_RE = /^([ \t]*)([-*+])([ \t]+)(.*)$/;
const TASK_BOX_RE = /^\[[ xX]\](?:[ \t]+|$)/;
const NOT_A_LIST = new Set(['FencedCode', 'CodeBlock', 'Frontmatter']);

function inCodeOrFrontmatter(state: EditorState, pos: number): boolean {
  const tree = syntaxTree(state);
  let node: ReturnType<typeof tree.resolveInner> | null = tree.resolveInner(pos, -1);
  for (; node; node = node.parent) if (NOT_A_LIST.has(node.name)) return true;
  return false;
}

function mdBulletEnterRun(
  view: EditorView,
  isInMathContext: (state: EditorState, pos: number) => boolean,
): boolean {
  const { state } = view;
  const sel = state.selection.main;
  if (!sel.empty) return false;
  const pos = sel.head;
  if (isInMathContext(state, pos)) return false;

  const line = state.doc.lineAt(pos);
  const m = line.text.match(MD_BULLET_RE);
  if (!m) return false;
  if (inCodeOrFrontmatter(state, pos)) return false;
  const [, indent, bullet, gap] = m;
  const box = m[4].match(TASK_BOX_RE)?.[0] ?? '';
  const body = m[4].slice(box.length);

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

  const markerEnd = line.from + indent.length + bullet.length + gap.length + box.length;
  if (pos < markerEnd) return false;

  // Mid-line Enter splits the item, like the default minus the blank line.
  const insert = `\n${indent}${bullet} ${box ? '[ ] ' : ''}`;
  view.dispatch({
    changes: { from: pos, to: pos, insert },
    selection: { anchor: pos + insert.length },
    userEvent: 'input',
    scrollIntoView: true,
  });
  return true;
}

export function mdListNewlineKeymap(
  isInMathContext: (state: EditorState, pos: number) => boolean,
): Extension {
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
