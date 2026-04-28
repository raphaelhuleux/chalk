# Chalk TODO

## Features

### Tab to exit math scope

In math mode, `Tab` should jump the cursor:
1. Past the next unmatched `}` if inside braces (e.g. `\frac{a|}{b}` → `\frac{a}|{b}`)
2. Past the math close delimiter if not inside braces (`$`, `$$`, `\)`, `\]`,
   `\end{equation}`, `\end{align}`, …)

Constraints:
- Must not break hsnips tab-stop advance ([hsnips-plugin.ts](src/webview/editor/hsnips-plugin.ts)) — chain in front via `Prec.high`, return `true` only when the cursor actually moved.
- Must not steal Tab from CM6 autocomplete-accept or default indent outside math.
- Reuse `isInMathContextTex` to gate; add a sibling walker that finds the next brace/math close at depth 0.

## Bugs

### Left-arrow into trailing inline math jumps to start of math

Repro: `$x^2$|` (cursor immediately after the closing `$`). Press Left.

Expected: cursor moves one character left, landing just inside the closing `$` — `$x^2|$`.

Actual: cursor lands at the start of the math span — `$|x^2$`.

### Down-arrow over display math skips the whole block

Repro: cursor on the empty line directly above a `$$ … $$` block. Press Down.

```
|              ←  cursor here
$$
\alpha
$$
```

Expected: cursor enters the block — e.g. `$$|` or on the `\alpha` line.

Actual: cursor lands on the line *below* the closing `$$`, skipping the entire math block.

### Shared root cause for both arrow-key bugs

Both stem from the math decoration being an **atomic block/inline widget** rather than a "hide source, preserve cursor positions" decoration:

- Inline math (`$…$`) is built as a single replacement that swallows internal positions, so Left from after-close collapses to the start of the span instead of stepping by one character into the hidden source.
- Display math (`$$…$$`) is built as a block widget that registers as one visual line, so Down treats the entire `$$\n…\n$$` block as a single line to skip past.

Look at how decorations are constructed in [src/webview/editor/tex-math.ts](src/webview/editor/tex-math.ts) (or wherever the display- and inline-math decorations live). The fix is likely:
- inline: use a `Decoration.replace` with `inclusive: false` and let CM6 step through positions, or shrink the replacement range so the closing delimiter remains a real cursor target.
- display: replace the block-widget approach with line decorations + a widget on a side, so the `$$\n…\n$$` source still counts as 3 navigable lines.

Once we touch this, write a small CM6 test that places the cursor at `$x^2$|` and `|\n$$...$$`, fires Left/Down, and asserts the resulting cursor position.
