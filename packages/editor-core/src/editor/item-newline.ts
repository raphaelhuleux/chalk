import { EditorState, Extension, Prec } from '@codemirror/state';
import { EditorView, keymap } from '@codemirror/view';

/**
 * Smart Enter on `\item` lines, caret past the token: a non-empty item splits
 * into a new `\item`; an empty one is deleted and the caret moves to a fresh
 * line after the enclosing env's `\end`. Math context falls through.
 */

type LineGetter = (n: number) => string | null;

const ENV_TOKEN_RE = /\\(begin|end)\{([^}]+)\}/g;

/** Walk upward from `fromLine - 1` for the innermost unclosed `\begin{X}`.
 *  Tokens on each line are read right-to-left, matching the upward walk. */
export function findEnclosingEnv(
  getLine: LineGetter,
  fromLine: number,
): { name: string; line: number } | null {
  let depth = 0;
  for (let n = fromLine - 1; n >= 1; n--) {
    const text = getLine(n);
    if (text === null) break;
    const matches = [...text.matchAll(ENV_TOKEN_RE)];
    for (let i = matches.length - 1; i >= 0; i--) {
      const [, kind, name] = matches[i];
      if (kind === 'end') {
        depth++;
      } else {
        if (depth === 0) return { name, line: n };
        depth--;
      }
    }
  }
  return null;
}

/** Forward-scan from `fromLine + 1` for the matching `\end{envName}`, skipping
 *  nested same-named envs. */
export function findMatchingEnd(
  getLine: LineGetter,
  fromLine: number,
  envName: string,
  maxLines = Number.POSITIVE_INFINITY,
): number | null {
  let depth = 0;
  for (let n = fromLine + 1; n <= maxLines; n++) {
    const text = getLine(n);
    if (text === null) break;
    for (const [, kind, name] of text.matchAll(ENV_TOKEN_RE)) {
      if (name !== envName) continue;
      if (kind === 'begin') {
        depth++;
      } else {
        if (depth === 0) return n;
        depth--;
      }
    }
  }
  return null;
}

const ITEM_LINE_RE = /^(\s*)\\item\b\s*(.*)$/;

function stateLineGetter(state: EditorState): LineGetter {
  return (n) => (n >= 1 && n <= state.doc.lines ? state.doc.line(n).text : null);
}

/** The Enter command, exported for tests. False falls through to default Enter. */
export function itemEnterRun(
  view: EditorView,
  isInMathContext: (state: EditorState, pos: number) => boolean,
): boolean {
  const { state } = view;
  const sel = state.selection.main;
  if (!sel.empty) return false;
  const pos = sel.head;
  if (isInMathContext(state, pos)) return false;

  const itemLine = state.doc.lineAt(pos);
  const m = itemLine.text.match(ITEM_LINE_RE);
  if (!m) return false;
  const [, indent, body] = m;
  // Before or inside the `\item` token, Enter is a plain newline.
  if (pos - itemLine.from < indent.length + '\\item'.length) return false;

  if (body.trim().length > 0) {
    const insert = `\n${indent}\\item `;
    view.dispatch({
      changes: { from: pos, to: pos, insert },
      selection: { anchor: pos + insert.length },
      userEvent: 'input',
    });
    return true;
  }

  const getLine = stateLineGetter(state);
  const env = findEnclosingEnv(getLine, itemLine.number);
  if (!env) return false;
  const endLineNum = findMatchingEnd(
    getLine,
    itemLine.number,
    env.name,
    state.doc.lines,
  );
  if (endLineNum === null) return false;
  const endLine = state.doc.line(endLineNum);

  // The deletion shifts later positions left by `deleteLen`.
  const deleteFrom = itemLine.from;
  const deleteTo = Math.min(itemLine.to + 1, state.doc.length);
  const deleteLen = deleteTo - deleteFrom;
  const cursor = endLine.to - deleteLen + 1;

  view.dispatch({
    changes: [
      { from: deleteFrom, to: deleteTo, insert: '' },
      { from: endLine.to, to: endLine.to, insert: '\n' },
    ],
    selection: { anchor: cursor },
    userEvent: 'input',
  });
  return true;
}

export function itemNewlineKeymap(
  isInMathContext: (state: EditorState, pos: number) => boolean,
): Extension {
  return Prec.high(
    keymap.of([
      {
        key: 'Enter',
        run: (view: EditorView) => itemEnterRun(view, isInMathContext),
      },
    ]),
  );
}
