import type { Line, Text } from '@codemirror/state';

/**
 * The line-level LaTeX facts the tex scanners share: which lines a verbatim
 * environment swallows, where a `%` comment starts, how far a `{…}` group
 * reaches. Readers with different rules keep their own copy on purpose (a
 * helper that quietly changes one scanner's answer is worse); each is named
 * at the helper below.
 */

/**
 * Verbatim-family environments whose bodies must not be read (a quoted
 * `\end{frame}` in a `[fragile]` frame would otherwise close the real one).
 * The open fence may carry args; inside, ONLY the matching `\end{<same env>}`
 * exits, as verbatim bodies don't nest in LaTeX. outline.ts keeps its own,
 * wider `VERBATIM_LIKE` family over the flattened document.
 */
export const VERBATIM_OPEN = /^\s*\\begin\{(verbatim\*?|lstlisting|minted)\}/;
export const VERBATIM_CLOSE = /^\s*\\end\{(verbatim\*?|lstlisting|minted)\}\s*$/;

/** A document line plus whether a verbatim environment owns it. Both fence
 *  lines count as verbatim: no scanner reads structure out of them. */
export interface TexLine {
  line: Pick<Line, 'from' | 'number' | 'text'>;
  verbatim: boolean;
}

/**
 * Walk the document's lines, flagging the ones a verbatim-family environment
 * swallows. tex-frame-plugin keeps its own walk: it lets the enclosing
 * frame's `\end{frame}` escape an unclosed verbatim, which a line flag can't.
 */
export function* texLines(doc: Text): Generator<TexLine> {
  let env: string | null = null;
  // iterLines with a running offset: `doc.line(n)` is a tree lookup per line.
  let from = 0;
  let number = 0;
  for (const text of doc.iterLines()) {
    const line = { from, number: ++number, text };
    from += text.length + 1;
    if (env !== null) {
      const end = VERBATIM_CLOSE.exec(line.text);
      if (end && end[1] === env) env = null;
      yield { line, verbatim: true };
      continue;
    }
    const open = VERBATIM_OPEN.exec(line.text);
    if (open) {
      env = open[1];
      yield { line, verbatim: true };
      continue;
    }
    yield { line, verbatim: false };
  }
}

/**
 * Index of the first unescaped `%` in `text`, or -1. A backslash consumes the
 * next char, so `\%` is literal and `\\%` starts a comment.
 */
export function commentStart(text: string): number {
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '\\') i++;
    else if (text[i] === '%') return i;
  }
  return -1;
}

/** Whether `pos` sits inside a `%` comment on `line`. */
export function inLineComment(line: { from: number; text: string }, pos: number): boolean {
  const cs = commentStart(line.text);
  return cs !== -1 && pos - line.from > cs;
}

/** Strip a trailing `%` line comment, so `\begin{frame}{T} % note` still parses. */
export function uncommented(text: string): string {
  const cs = commentStart(text);
  return cs === -1 ? text : text.slice(0, cs);
}

/**
 * Index of the `}` closing the group opened just before `argStart`, or -1.
 * Skips `\`-escaped chars. outline.ts's `readBracedArg` differs (no escapes,
 * stops at a newline) and keeps its own reader.
 */
export function findClosingBrace(text: string, argStart: number): number {
  let depth = 1;
  let j = argStart;
  while (j < text.length) {
    const c = text[j];
    if (c === '\\') {
      j += 2;
      continue;
    }
    if (c === '{') depth++;
    else if (c === '}') {
      depth--;
      if (depth === 0) return j;
    }
    j++;
  }
  return -1;
}

/** Read the brace group opening at `open`: trimmed inner text and the index
 *  past its `}`, or null when unbalanced. */
export function readGroup(s: string, open: number): { value: string; end: number } | null {
  if (s[open] !== '{') return null;
  const close = findClosingBrace(s, open + 1);
  if (close === -1) return null;
  return { value: s.slice(open + 1, close).trim(), end: close + 1 };
}
