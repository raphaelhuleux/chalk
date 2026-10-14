import { forceParsing } from '@codemirror/language';
import type { EditorView } from '@codemirror/view';

/**
 * Finish parsing before the test looks at the tree.
 *
 * CM6 parses on a wall-clock budget and defers the remainder to an async
 * continuation (`requestIdleCallback`, or `setTimeout` under jsdom) that never
 * runs inside a synchronous test. On an idle machine the whole document fits
 * in the first slice and nothing is visibly wrong; under vitest's parallel
 * workers the slice can expire mid-document, leaving a partial tree. Every
 * decoration built from `syntaxTree` then silently comes up short, and which
 * test loses the race moves around with scheduling — the failure looked like
 * three unrelated flaky tests (table-in-callout, frontmatter, equation
 * numbering) rather than one cause.
 *
 * Not something production needs: forcing a full synchronous parse on mount
 * would block the UI on a large document, which is exactly what the budget
 * exists to prevent.
 */
export function parsed(view: EditorView): EditorView {
  forceParsing(view, view.state.doc.length, 10_000);
  return view;
}
