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
import {
  EditorSelection,
  EditorState,
  Extension,
  Facet,
  StateEffect,
  StateField,
} from '@codemirror/state';
import { docText } from '../utils/doc-text';

interface Jump {
  from: number;
  to: number;
}

const pushJump = StateEffect.define<Jump>();
const popJump = StateEffect.define<null>();

/**
 * The tabout jumps Shift-Tab can still walk back, newest last. An edit or a
 * caret move to anywhere but the last landing ends the walk, so Shift-Tab
 * never teleports the caret to a spot the reader has left.
 */
const jumpTrail = StateField.define<readonly Jump[]>({
  create: () => [],
  update(trail, tr) {
    for (const e of tr.effects) {
      if (e.is(pushJump)) return [...trail, e.value];
      if (e.is(popJump)) return trail.slice(0, -1);
    }
    if (trail.length === 0) return trail;
    if (tr.docChanged) return [];
    if (!tr.selection) return trail;
    const sel = tr.selection.main;
    return sel.empty && sel.head === trail[trail.length - 1].to ? trail : [];
  },
});

type TargetFn = (state: EditorState) => number | null;

/**
 * Where Tab's tabout would put the caret, or null when it would fall through.
 * hsnips reads it so an exit inside the current stop beats the next stop.
 */
export const taboutTargetFacet = Facet.define<TargetFn, TargetFn>({
  combine: (values) => values[0] ?? (() => null),
});

/**
 * Null on a non-empty selection (indent owns it), with only whitespace before
 * the caret on its line (indent: no scope has been entered there to exit),
 * outside math, or with no exit before EOF.
 */
function taboutTarget(
  state: EditorState,
  isInMathContext: (state: EditorState, pos: number) => boolean,
  lang: 'tex' | 'md',
): number | null {
  const sel = state.selection.main;
  if (!sel.empty) return null;
  const line = state.doc.lineAt(sel.head);
  if (/^\s*$/.test(state.sliceDoc(line.from, sel.head))) return null;
  if (!isInMathContext(state, sel.head)) return null;
  return scanForExit(docText(state.doc), sel.head, lang);
}

/** The Tab command (exported for tests); falls through where `taboutTarget` is null. */
export function taboutCommand(
  isInMathContext: (state: EditorState, pos: number) => boolean,
  lang: 'tex' | 'md',
): (view: EditorView) => boolean {
  return (view) => {
    const sel = view.state.selection.main;
    const target = taboutTarget(view.state, isInMathContext, lang);
    if (target === null) return false;
    view.dispatch({
      selection: EditorSelection.cursor(target),
      effects: pushJump.of({ from: sel.head, to: target }),
      scrollIntoView: true,
    });
    return true;
  };
}

/**
 * Shift-Tab right after a tabout (exported for tests): the caret goes back to
 * where that Tab took it from, one jump per press. Falls through otherwise.
 */
export function taboutBackCommand(view: EditorView): boolean {
  const trail = view.state.field(jumpTrail, false);
  const last = trail?.[trail.length - 1];
  const sel = view.state.selection.main;
  if (!last || !sel.empty || sel.head !== last.to) return false;
  view.dispatch({
    selection: EditorSelection.cursor(last.from),
    effects: popJump.of(null),
    scrollIntoView: true,
  });
  return true;
}

/**
 * Math-gated Tab that exits the current scope, and the Shift-Tab that undoes
 * it. NOT `Prec.high`: it must stay below hsnips' Tab or `\frac{$1}{$2}` would
 * jump past `}` instead of to $2. setup.ts registration order gives
 * hsnips → autocomplete → tabout → indent, for Shift-Tab too.
 */
export function taboutKeymap(
  isInMathContext: (state: EditorState, pos: number) => boolean,
  lang: 'tex' | 'md',
): Extension {
  return [
    jumpTrail,
    taboutTargetFacet.of((state) => taboutTarget(state, isInMathContext, lang)),
    keymap.of([
      { key: 'Tab', run: taboutCommand(isInMathContext, lang) },
      { key: 'Shift-Tab', run: taboutBackCommand },
    ]),
  ];
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
