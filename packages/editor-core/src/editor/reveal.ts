import { Decoration } from '@codemirror/view';
import { SelectionRange } from '@codemirror/state';

/**
 * Reveal-on-caret rules for inline live preview. Two facts drive them:
 *
 *  1. Revealing widens the line, reflowing text under a selection being made
 *     (and can change a wrapped line's row count). So a selection that CROSSES
 *     a construct's edge never reveals it.
 *  2. A replace decoration has no DOM position inside it: CM6 moves a selection
 *     end there to the outer edge and the next keystroke lands in the wrong
 *     place. So a selection end STRANDED inside a hidden range reveals it.
 *
 * A selection on a construct's visible text strands nothing and stays
 * concealed; tex-conceal-plugin.ts's pointer-gesture contracts depend on that.
 */

/** A selection end strictly inside [from, to); ends on an edge survive. */
function strandedIn(main: SelectionRange, from: number, to: number): boolean {
  return (main.from > from && main.from < to) || (main.to > from && main.to < to);
}

/**
 * `[from, to)` (`[from, to]` when `endInclusive`) is the caret's reveal window;
 * `[from, openTo)` and `[closeFrom, to)` are the hidden ranges.
 */
function revealFor(
  main: SelectionRange,
  from: number,
  to: number,
  openTo: number,
  closeFrom: number,
  endInclusive: boolean,
): boolean {
  if (main.empty) {
    return main.head >= from && (endInclusive ? main.head <= to : main.head < to);
  }
  if (main.from < from || main.to > to) return false; // crosses an edge
  return strandedIn(main, from, openTo) || strandedIn(main, closeFrom, to);
}

/**
 * Reveal for a collapsed caret inside [from, to) only; no selection reveals.
 * Prefer revealReplacedSource / revealDelimitedSource, which know the hidden ranges.
 */
export function revealSource(main: SelectionRange, from: number, to: number): boolean {
  return revealFor(main, from, to, from, to, false);
}

/**
 * For a construct replaced whole (formula, image, `\ref` pill). A selection
 * covering it exactly stays rendered: that is what a drag across it produces,
 * and revealing would flash the source open mid-gesture.
 */
export function revealReplacedSource(
  main: SelectionRange,
  from: number,
  to: number,
): boolean {
  return revealFor(main, from, to, to, to, false);
}

/**
 * `revealReplacedSource` for a construct that ends a line (the crossref pill):
 * the line-end position is the only one that edits its last character, so it
 * must count as inside.
 */
export function revealReplacedSourceInclusive(
  main: SelectionRange,
  from: number,
  to: number,
): boolean {
  return revealFor(main, from, to, to, to, true);
}

/**
 * For a construct that hides only its delimiters (`**bold**`, `\emph{word}`, a
 * link). A selection on the visible argument stays concealed, so a double-click
 * word-select doesn't reflow the line.
 */
export function revealDelimitedSource(
  main: SelectionRange,
  from: number,
  to: number,
  openTo: number,
  closeFrom: number,
): boolean {
  return revealFor(main, from, to, openTo, closeFrom, false);
}

/** `revealDelimitedSource` for a construct that ends a line (the Quarto
 *  heading id); see revealReplacedSourceInclusive. */
export function revealDelimitedSourceInclusive(
  main: SelectionRange,
  from: number,
  to: number,
  openTo: number,
  closeFrom: number,
): boolean {
  return revealFor(main, from, to, openTo, closeFrom, true);
}

/** `revealDelimitedSource` with the first and last marks as the hidden
 *  ranges; under two marks nothing is concealed, so only the caret rule applies. */
export function revealMarked(
  main: SelectionRange,
  from: number,
  to: number,
  marks: ReadonlyArray<{ from: number; to: number }>,
): boolean {
  if (marks.length < 2) return revealSource(main, from, to);
  return revealDelimitedSource(main, from, to, marks[0].to, marks[marks.length - 1].from);
}

/**
 * Whether a line-level construct (fence, folded title, hidden indent) reveals.
 * `[hiddenFrom, hiddenTo]` is what it hides (a collapsed row's starts at the
 * previous line's end). Reveals for a caret on the line, a selection anchored on
 * it (so extending from a revealed fence never collapses the row mid-selection),
 * or a stranded end (fact 2). A selection merely passing over stays concealed
 * (fact 1).
 */
export function lineRevealed(
  main: SelectionRange,
  from: number,
  to: number,
  hiddenFrom: number = from,
  hiddenTo: number = to,
): boolean {
  if (main.empty) return main.head >= from && main.head <= to;
  if (main.anchor >= from && main.anchor <= to) return true;
  return strandedIn(main, hiddenFrom, hiddenTo);
}

/** Mixed mode: what Preview would hide stays visible, dimmed. */
export const SYNTAX_DIM = Decoration.mark({ class: 'cm-syntax-dim' });

/** A plain hide; one shared instance, since every use is identical. */
export const HIDE = Decoration.replace({});
