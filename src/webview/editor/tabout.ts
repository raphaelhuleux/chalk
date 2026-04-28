/**
 * Pure forward-scanner for the Tabout feature. Walks `text` from `from`
 * looking for the first closing-scope delimiter and returns the position
 * just past it, or null if none is found before EOF.
 *
 * `lang` controls language-specific tokens — currently just whether `%`
 * starts a line comment (true for tex, false for markdown).
 *
 * The scan does NOT track `{`/`[`/`(` opens; the first unmatched close
 * found wins. `\left⟨c⟩` / `\right⟨c⟩` ARE tracked as a pair so that an
 * inner balanced `\left…\right` doesn't consume the user's outer exit.
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

    // Tex line comment — skip to end of line.
    if (lang === 'tex' && c === '%') {
      const nl = text.indexOf('\n', i);
      i = nl === -1 ? text.length : nl + 1;
      continue;
    }

    // Backslash-prefixed tokens
    if (c === '\\') {
      // \left⟨delim⟩ — push depth.
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
      // \right⟨delim⟩ — pop or exit.
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
      // Math-close commands
      if (text[i + 1] === ')') return i + 2;
      if (text[i + 1] === ']') return i + 2;
      if (text.startsWith('\\end{', i)) {
        const closeBrace = text.indexOf('}', i + 5);
        if (closeBrace !== -1) return closeBrace + 1;
      }
      // Other escape — skip 2 chars (covers \\, \$, \{, \}, \%, \alpha, …)
      i += 2;
      continue;
    }

    // Closing brackets
    if (c === '}' || c === ']' || c === ')') return i + 1;

    // Math close — `$$` first to not split it into two `$`
    if (c === '$') {
      if (text[i + 1] === '$') return i + 2;
      return i + 1;
    }

    i++;
  }
  return null;
}

// -----------------------------------------------------------------------
// CM6 command + keymap factory
// -----------------------------------------------------------------------

import { EditorView, keymap } from '@codemirror/view';
import { EditorSelection, EditorState, Extension, Prec } from '@codemirror/state';

/**
 * Returns the Tab `run` command — exported separately from the keymap
 * so tests can call it directly with a view, no keymap-event plumbing.
 *
 * Falls through (returns false) when:
 *   - the selection is non-empty (let indent handle a multi-line indent),
 *   - the cursor is outside any math context,
 *   - no exit delimiter is reachable before EOF.
 */
export function taboutCommand(
  isInMathContext: (state: EditorState, pos: number) => boolean,
  lang: 'tex' | 'md',
): (view: EditorView) => boolean {
  return (view) => {
    const sel = view.state.selection.main;
    if (!sel.empty) return false;
    if (!isInMathContext(view.state, sel.head)) return false;
    const target = scanForExit(view.state.doc.toString(), sel.head, lang);
    if (target === null) return false;
    view.dispatch({
      selection: EditorSelection.cursor(target),
      scrollIntoView: true,
    });
    return true;
  };
}

/**
 * Math-gated Tab → forward-scope-exit keymap, wrapped in `Prec.high`
 * for predictable ordering. Slot AFTER hsnips and acceptCompletion so
 * snippet tabstops and active autocomplete popups win over Tabout, and
 * BEFORE indentWithTab so indent is the fallback.
 */
export function taboutKeymap(
  isInMathContext: (state: EditorState, pos: number) => boolean,
  lang: 'tex' | 'md',
): Extension {
  return Prec.high(
    keymap.of([{ key: 'Tab', run: taboutCommand(isInMathContext, lang) }]),
  );
}

/**
 * Reads the delimiter following `\left` / `\right`. Supports:
 *   - single chars: ( ) [ ] < > . |
 *   - escaped: \{ \} \|
 *   - letter-form commands: \langle, \rangle, \lvert, \rvert, etc.
 * Returns the index immediately AFTER the delim, or `i` if no delim
 * sits at position `i` (caller should not advance in that case).
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
