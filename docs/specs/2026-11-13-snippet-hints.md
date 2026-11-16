# Shortcut hints

While typing math, a list under the caret shows the snippets that match what you just typed: each one's output (rendered), its description and its trigger.
It teaches the shortcuts for commands you already know, and doubles as a picker.
Off by default: Settings > Editor > Shortcut Hints on the Mac, `chalk.snippetHints` in VS Code.
Code: `packages/editor-core/src/editor/snippet-hints.ts`.

## What opens the list

- The start of a trigger: `/` lists `//`, `;t` lists `;th` and `;ta`.
- A hand-typed command name of two letters or more: `\fr` lists `//`, because its output contains `\frac`.
- One character is enough only for the leaders `;`, `/` and `:`. A prefix starting with `_` or `^` needs three characters, any other prefix two. Otherwise every `=`, `-`, `,` or `x_t` would open the list and take Tab.
- A prefix starting with a letter must start a word, so `xsu` lists nothing.
- Only typing opens it. A caret move, a host update or an expansion closes it, so Tab after moving the caret is still tabout.
- Never outside math, inside `\text{}`, inside a name argument (`\label{`, `\begin{`), or while the completion popup is open.
- Regex snippets are never listed: their trigger isn't readable and their output depends on the captures.
- At most eight rows. Longer typed prefix first, then shorter trigger, then priority, then file order.

## Keys

- Tab inserts the highlighted hint over what was typed, and starts its tab stops as a typed trigger would.
- Up/Down move the highlight, wrapping. With one row they move the caret as usual.
- Escape hides the list until the next keystroke.
- Enter is never taken: it is a new row in `align`.
- A command typed out in full (`\alpha`) lists its shortcut, but Tab goes on to tabout, since inserting it would change nothing.
- Clicking a row inserts it.

## Limits

- VS Code users with their own `latex.hsnips` see hints from that file only, since it replaces the defaults there.
- The preview shows empty tab stops as a box. If KaTeX can't render an output (an `align` body in inline mode, say), the row shows the raw text instead.
