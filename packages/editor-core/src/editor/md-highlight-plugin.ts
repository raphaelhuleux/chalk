import type { MarkdownConfig, InlineParser, InlineContext } from '@lezer/markdown';
import { tags } from '@lezer/highlight';

// Lezer inline parser for `==highlight==`, shaped like the inline-math one: a
// same-line scan emitting two HighlightMark children for md-live-preview to hide.

const EQUALS = 61; // '='.charCodeAt(0)
const BACKSLASH = 92; // '\'.charCodeAt(0)
const NEWLINE = 10; // '\n'.charCodeAt(0)

const highlightParser: InlineParser = {
  name: 'Highlight',

  parse(cx: InlineContext, next: number, pos: number): number {
    if (next !== EQUALS) return -1;
    if (cx.char(pos + 1) !== EQUALS) return -1;
    // Not the second '=' of a pair, and not the start of a longer '=' run.
    if (pos > cx.offset && cx.char(pos - 1) === EQUALS) return -1;
    if (cx.char(pos + 2) === EQUALS) return -1;

    let end = pos + 2;
    while (end < cx.end) {
      const ch = cx.char(end);

      if (ch === NEWLINE) return -1;
      if (ch === BACKSLASH) {
        end += 2;
        continue;
      }

      if (ch === EQUALS && cx.char(end + 1) === EQUALS) {
        if (cx.char(end + 2) === EQUALS) return -1;
        if (end === pos + 2) return -1; // empty '===='

        return cx.addElement(
          cx.elt('Highlight', pos, end + 2, [
            cx.elt('HighlightMark', pos, pos + 2),
            cx.elt('HighlightMark', end, end + 2),
          ]),
        );
      }

      end++;
    }

    return -1;
  },
};

/** MarkdownConfig for the Highlight nodes. Register it after mathSyntax so
 *  `$…$` is claimed by the math parser first. */
export const highlightSyntax: MarkdownConfig = {
  defineNodes: [
    { name: 'Highlight' },
    { name: 'HighlightMark', style: tags.processingInstruction },
  ],
  parseInline: [highlightParser],
};
