/**
 * Tabout scanner: the position just past the first closing-scope delimiter
 * after `from`, or null. `lang` only decides whether `%` starts a comment.
 *
 * `{`/`[`/`(` opens are not tracked; the first close wins. `\left`/`\right`
 * are, so an inner balanced pair doesn't consume the outer exit. Pairing is
 * depth-only: a malformed `\left( … \right]` still cancels, since that source
 * won't render anyway (as Obsidian's latex-suite does).
 */
export function scanForExit(
  text: string,
  from: number,
  lang: 'tex' | 'md',
): number | null {
  let i = from;
  let leftDepth = 0;

  while (i < text.length) {
    const c = text[i];

    if (lang === 'tex' && c === '%') {
      const nl = text.indexOf('\n', i);
      i = nl === -1 ? text.length : nl + 1;
      continue;
    }

    if (c === '\\') {
      if (
        text.startsWith('\\left', i) &&
        !/[A-Za-z]/.test(text[i + 5] ?? '')
      ) {
        const after = readLeftRightDelim(text, i + 5);
        if (after > i + 5) {
          leftDepth++;
          i = after;
          continue;
        }
      }
      if (
        text.startsWith('\\right', i) &&
        !/[A-Za-z]/.test(text[i + 6] ?? '')
      ) {
        const after = readLeftRightDelim(text, i + 6);
        if (after > i + 6) {
          if (leftDepth > 0) {
            leftDepth--;
            i = after;
            continue;
          }
          return after;
        }
      }
      if (text[i + 1] === ')') return i + 2;
      if (text[i + 1] === ']') return i + 2;
      if (text.startsWith('\\end{', i)) {
        const closeBrace = text.indexOf('}', i + 5);
        if (closeBrace !== -1) return closeBrace + 1;
      }
      // Any other escape (\\, \$, \{, \%, \alpha…): skip the backslash pair.
      i += 2;
      continue;
    }

    if (c === '}' || c === ']' || c === ')') return i + 1;

    // `$$` first so it isn't split into two `$`.
    if (c === '$') {
      if (text[i + 1] === '$') return i + 2;
      return i + 1;
    }

    i++;
  }
  return null;
}

import { EditorView, keymap } from '@codemirror/view';
import { EditorSelection, EditorState, Extension } from '@codemirror/state';
import { docText } from '../utils/doc-text';

/**
 * The Tab command (exported for tests). Falls through on a non-empty
 * selection (indent owns it), outside math, or with no exit before EOF.
 */
export function taboutCommand(
  isInMathContext: (state: EditorState, pos: number) => boolean,
  lang: 'tex' | 'md',
): (view: EditorView) => boolean {
  return (view) => {
    const sel = view.state.selection.main;
    if (!sel.empty) return false;
    if (!isInMathContext(view.state, sel.head)) return false;
    const target = scanForExit(docText(view.state.doc), sel.head, lang);
    if (target === null) return false;
    view.dispatch({
      selection: EditorSelection.cursor(target),
      scrollIntoView: true,
    });
    return true;
  };
}

/**
 * Math-gated Tab that exits the current scope. NOT `Prec.high`: it must stay
 * below hsnips' Tab or `\frac{$1}{$2}` would jump past `}` instead of to $2.
 * setup.ts registration order gives hsnips → autocomplete → tabout → indent.
 */
export function taboutKeymap(
  isInMathContext: (state: EditorState, pos: number) => boolean,
  lang: 'tex' | 'md',
): Extension {
  return keymap.of([
    { key: 'Tab', run: taboutCommand(isInMathContext, lang) },
  ]);
}

/**
 * The index just past the delimiter after `\left`/`\right` (a char from
 * `()[]<>.|`, `\{ \} \|`, or a letter command like `\langle`), or `i` if none.
 */
function readLeftRightDelim(text: string, i: number): number {
  if (i >= text.length) return i;
  const c = text[i];
  if (c === '\\') {
    const next = text[i + 1];
    if (next === '{' || next === '}' || next === '|') return i + 2;
    if (next && /[A-Za-z]/.test(next)) {
      let j = i + 1;
      while (j < text.length && /[A-Za-z]/.test(text[j])) j++;
      return j;
    }
    return i;
  }
  if ('()[]<>.|'.includes(c)) return i + 1;
  return i;
}
