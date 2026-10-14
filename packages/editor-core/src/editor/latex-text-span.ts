/**
 * Detects `\text{…}` and friends: prose inside a math region, where math
 * snippets must not fire (as in upstream HyperSnips), or `$\text{number}$`
 * expands `nu`. Used only to narrow the hsnips `math(context)` filter in
 * setup.ts; `isInMathContextTex` stays unchanged because tabout, math-wrap and
 * item-newline mean "inside math delimiters".
 */

import type { EditorState } from '@codemirror/state';

/** Commands whose braced argument is typeset as prose rather than math. */
const TEXT_COMMANDS = new Set([
  'text',
  'textrm',
  'textbf',
  'textit',
  'textsf',
  'texttt',
  'textnormal',
  'mbox',
  'intertext',
]);

/** Whether the `{` at `brace` opens a text command's argument. Reads backward,
 *  so each `{` costs the command's length, not a regex over the prefix. */
function opensTextArgument(s: string, brace: number): boolean {
  let end = brace;
  while (end > 0 && /\s/.test(s[end - 1])) end--;
  let start = end;
  while (start > 0 && /[A-Za-z]/.test(s[start - 1])) start--;
  return start > 0 && s[start - 1] === '\\' && TEXT_COMMANDS.has(s.slice(start, end));
}

/** True when `pos` is inside a text command's argument. Scans only the line
 *  prefix (cheap per keystroke; a multi-line `\text{}` is pathological). */
export function isInLatexTextSpan(state: EditorState, pos: number): boolean {
  const line = state.doc.lineAt(pos);
  const prefix = line.text.slice(0, pos - line.from);

  let depth = 0;
  // Depths at which a text command opened; a stack, so nested groups inside
  // `\text{…}` still read as prose.
  const textDepths: number[] = [];

  for (let i = 0; i < prefix.length; i++) {
    const c = prefix[i];
    if (c === '\\') {
      i++; // `\{`, `\}` and `\\` are literals, not group delimiters
      continue;
    }
    if (c === '{') {
      depth++;
      if (opensTextArgument(prefix, i)) textDepths.push(depth);
      continue;
    }
    if (c === '}') {
      if (textDepths[textDepths.length - 1] === depth) textDepths.pop();
      depth--;
    }
  }

  return textDepths.length > 0;
}
