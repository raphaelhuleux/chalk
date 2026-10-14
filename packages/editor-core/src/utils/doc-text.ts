import { Text } from '@codemirror/state';
import { memoByDoc } from './memo-by-doc';

// Counts real flattens; typing-perf.test.ts pins one per document change.
let flattens = 0;
export function __docTextCount(): number {
  return flattens;
}
export function __resetDocTextCount(): void {
  flattens = 0;
}

/**
 * The document as one string, flattened at most once per `Text`. Use this, not
 * `doc.toString()`: the regex scanners and the host `edit` share it, and
 * separate flattens were a measurable share of keystroke time on large docs.
 */
export const docText = memoByDoc((doc: Text): string => {
  flattens++;
  return doc.toString();
});
