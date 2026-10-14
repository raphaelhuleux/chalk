# Typing slows down inside a very long markdown paragraph

Found 2026-08-26 while extending the bench past `.tex`.
Root cause identified, upstream, and NOT fixed: every available fix trades correctness for speed, and the exposure turns out to be narrow.
`md_long_paragraph_p95_ms` in `thresholds.json` watches it.

## The symptom

Typing cost in a `.md` file tracks the length of the PARAGRAPH the caret sits in, not the length of the document.
Identical prose, 5000 lines throughout, headless Chromium at 4x throttle, measured inside `view.dispatch`:

| paragraph length | per keystroke |
|---|---|
| 5000 lines (one paragraph) | 105.1 ms |
| 500 lines | 26.2 ms |
| 100 lines | 10.6 ms |
| 20 lines | 7.2 ms |
| 5 lines | 8.1 ms |

The cost is inside the state update, not before it: `keydown -> dispatch` stays at ~1.5 ms in every row above.

## The cause

Two upstream facts compose into it.

`@lezer/markdown`'s `Parse.advance()` consumes a whole leaf block in one call. From its block loop:

```js
lines: while (this.nextLine()) {
  ...
  leaf.content += "\n" + line.scrub();
}
this.finishLeaf(leaf);      // -> parser.parseInline(leaf.content, leaf.start)
```

A paragraph IS one leaf block, so a single `advance()` accumulates every line of it and runs the whole inline parse over the result.

`@codemirror/language` caps parse work per transaction at 20 ms (`Work.Apply`), but `ParseContext.work` checks the clock only BETWEEN `advance()` calls:

```js
for (;;) {
  let done = this.parse.advance();
  ...
  if (until()) return false;   // the budget is consulted here, after the fact
}
```

So the budget cannot preempt one long `advance()`. A 5000-line paragraph is one ~100 ms uninterruptible step, every keystroke.

## Which structures are affected

Measured at 2000 lines each, median ms per state update, unthrottled:

| structure | cost |
|---|---|
| one paragraph, no blank lines | 5.06 |
| unbroken blockquote | 5.52 |
| bullet list, one item per line | 0.03 |
| numbered list | 0.04 |
| paragraphs separated by blank lines | 0.02 |
| every line a heading | 0.04 |

Only two structures reach it: an unbroken paragraph and an unbroken blockquote.
A list is not affected — each item is its own block — and neither is ordinary prose with blank lines between paragraphs.
This is what makes it a narrow problem rather than a general one: it needs a single paragraph many hundreds of lines long, with no blank line anywhere in it.

## Why it is not fixed

The parser exposes exactly one lever, the `endLeaf` hook on a `parseBlock` spec, which ends a leaf block early. It works, dramatically — a 5000-line paragraph capped at 50 lines goes from 17.4 ms to 0.36 ms per update — and it is not safe:

- **Markup spanning a split is silently lost.** `**bold` opened on line 10 and closed on line 60 parses as `StrongEmphasis` normally and disappears entirely with a 50-line cap. This is not an edge case that can be guarded away: markdown inline constructs may legally span any number of lines within a paragraph, and a blank line is the ONLY boundary they cannot cross. There is therefore no sound split point inside a paragraph, by construction.
- **Long tables break.** A 60-row GFM table parsed with a 50-line cap yields 48 `TableRow`s and a stray `Paragraph`.
- **The obvious guard disables the fix.** Skipping the cap when `leaf.parsers.length > 0` keeps the table intact and also stops the cap firing for plain prose, because the Table and Setext parsers attach a leaf parser to every paragraph.

A larger cap shrinks the risk and the benefit together: the block being edited still costs its own length, so a 500-line cap leaves ~26 ms per keystroke, which is most of the problem.

The one LOSSLESS lever is dropping inline parsers the live preview never renders. Removing `HTMLTag`, `Entity` and `Autolink` measured 16.07 ms -> 14.05 ms on a 5000-line paragraph, about 12%. It does not change the scaling, and it costs those constructs their syntax nodes, so it was not taken either.

## If this ever needs fixing

Fix it upstream, not here. Either `@lezer/markdown` splits inline parsing of a leaf block into resumable steps, or `@codemirror/language` gains a way to bound the work of a single `advance()`. Both are real changes to those projects; neither has a workaround in this repo that keeps rendering correct.

Until then the honest mitigation is a blank line, which is also just ordinary markdown.
