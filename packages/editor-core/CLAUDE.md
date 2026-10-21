# @chalk/editor-core

Host-agnostic CodeMirror 6 + KaTeX + hsnips editor. Consumed by the native
Mac app (via `web/`) and the VS Code extension (`vscode/`). Its vitest
tests run in jsdom (`pnpm --filter @chalk/editor-core test`); mount a view with
[test/helpers/views.ts](test/helpers/views.ts) (`texView`, `mdView`, `langView`,
`mockPort`) rather than writing another per-file factory.

One entry point, `mountEditor(opts)` ([src/mount.ts](src/mount.ts)); one
contract, `HostPort` ([src/host-port.ts](src/host-port.ts)) — a frozen
9-message protocol. Everything else is internal.

Geometric caret/click behavior (wrapped rows, pixel goal columns, click
coordinates, reveal reflow) is NOT testable in jsdom. Every harness that needs
a real browser lives in one tree at the repo root, `Tests/`:

| Path | Command | What it drives |
|---|---|---|
| [Tests/browser/](../../Tests/browser/) | `pnpm test:browser` | scenario harness: pointer, motion, reveal reflow |
| [Tests/fixtures/](../../Tests/fixtures/) | `pnpm test:caret` | one plain-text file per caret/mouse case |
| [Tests/matrix/](../../Tests/matrix/) | `pnpm test:matrix:geo` | the caret/reveal discovery matrix |
| [Tests/runner/](../../Tests/runner/) | — | the runners and the shared `lib/` bootstrap |

All of them build `web/dist` and read editor state through the `?debug`-gated
`window.__chalkDebugView` hook in mount.ts; all of them pick their engine lane
from `CHALK_BROWSER` through
[Tests/runner/lib/browser.mjs](../../Tests/runner/lib/browser.mjs), and their
accepted-failure files share one tagged format
([Tests/runner/lib/known-failures.mjs](../../Tests/runner/lib/known-failures.mjs)).
Extend them whenever you touch reveal-on-caret, pointer-gesture, or
vertical-motion code; the jsdom twin for the logic level is
[test/tex-caret-click-matrix.test.ts](test/tex-caret-click-matrix.test.ts).

## Guardrails (learned the hard way — don't relitigate casually)

- **Stay host-agnostic.** No platform imports, no window-shell assumptions.
  The only host contact is the `HostPort`. The `--vscode-*` CSS variables in
  the theme are harmless — every one has a hardcoded fallback; rely on the
  fallback rather than ripping them out.
- **Don't replace the minimal-diff sync** ([src/utils/text-diff.ts](src/utils/text-diff.ts)).
  Host→editor `update`s apply as minimal text diffs so CM6 preserves cursor
  and viewport across autocomplete/snippet edits. Full-text replace loses
  both on every keystroke-driven edit.
- **GFM tables** render as an always-on editable `<table>` widget
  ([src/editor/table-field.ts](src/editor/table-field.ts) +
  [table-widget.ts](src/editor/table-widget.ts), pure model in
  [table-model.ts](src/editor/table-model.ts)). This is the one place
  live-preview uses `contenteditable`: cells are editable islands inside a
  block-replace widget; edits buffer in the DOM and flush to the pipe source
  as one transaction on blur/Escape/structural op. The table range is an
  `atomicRange`. v1 renders cell content as plain text — don't add rich
  in-cell rendering without weighing the selection-mapping cost.
- **LaTeX tabulars** (tabular, tabular*, tabularx, tabulary, longtable, tblr)
  render through their own widget
  ([tex-table-field.ts](src/editor/tex-table-field.ts) +
  [tex-table-widget.ts](src/editor/tex-table-widget.ts), pure model in
  [tex-table-model.ts](src/editor/tex-table-model.ts)). Two deliberate
  differences from GFM: the model keeps a document range for every cell, rule
  and spec column, and every edit is a change to those ranges, never a
  re-serialization (a tex user's spacing, comments and wrappers are theirs);
  and a cell shows rendered tex ([tex-cell-render.ts](src/editor/tex-cell-render.ts))
  until focused, then its raw source as plain text, which sidesteps selection
  mapping. A flush writes a cell only if its live source still equals what
  the DOM was built from. A table the parser can't read exactly (unbalanced
  braces, stray `\end`) stays source, as does one inside math. The replace
  covers whole lines, so text sharing the `\begin`/`\end` lines (a
  `\resizebox{…}{`'s `}`) shows as a dim strip in the widget.
- **Markdown live-preview scope**: headings, bold, italic, link, code,
  strikethrough, `==highlight==`, blockquote, math, GFM tables, and
  theorem-family callouts. Don't expand to footnotes/MDX without a concrete need.
  `---` is deliberately left as raw source (no `<hr>`): rendering it collapsed
  the line into a blank gap, so the HorizontalRule branch is a no-op.
- **Mermaid** ([md-mermaid-plugin.ts](src/editor/md-mermaid-plugin.ts)): a
  closed ```` ```mermaid ```` fence keeps its source and gains the diagram as a
  block widget under the closing fence (preview and mixed, not source); no
  reveal or caret changes. Minified mermaid is ~5 MB, so it never enters the
  editor bundle: each host builds [src/mermaid-entry.ts](src/mermaid-entry.ts)
  into its own `mermaid.js` and passes `scriptMermaidLoader` to `mountEditor`.
  The two scripts meet only through the global in
  [mermaid-api.ts](src/editor/mermaid-api.ts), which must stay import-free or
  its imports get bundled twice. No loader, no widgets. VS Code's CSP admits
  the injected script only with the page nonce.
- **TikZ** ([tikz-plugin.ts](src/editor/tikz-plugin.ts)): a `tikzpicture` /
  `tikzcd` outside math in .tex, or a ```` ```tikz ```` / ```` ```{tikz} ````
  fence, keeps its source and gains the typeset figure as a block widget under
  its last line, the mermaid pattern. The editor builds the whole standalone
  document ([tikz-source.ts](src/editor/tikz-source.ts): an allow-list of
  preamble commands, a deny-list of packages that break under
  pdflatex + standalone) and the host only compiles it, over the
  transport-internal `render-tikz` request; so the hosts can't drift. Without a
  `renderTikz` hook (VS Code today) nothing renders. Dark mode inverts the PNG
  in CSS (`cm-tikz-dark` on the editor root), so a theme flip re-renders
  nothing.
- **View modes** (preview / mixed / source, [src/editor/view-mode.ts](src/editor/view-mode.ts)):
  each language hands `viewModeExtension` three preview-compartment sets. Mixed
  is built by passing `{ conceal: false }` into the SAME builders, which turns
  every hide into a `cm-syntax-dim` mark and every reveal predicate off; a
  numbered callout's label floats as a `data-callout` chip (the slide-number
  `::after` trick). Don't add a second builder for Mixed, and don't make Mixed
  hide anything but math, images and tables. The host sends the DEFAULT in
  `editor-config.viewMode`; Cmd+: cycles one editor and a config push only
  resets it when the default itself changed.
- **Callouts**: one renderer, two surface syntaxes. Quarto fenced divs in
  [md-callout-plugin.ts](src/editor/md-callout-plugin.ts) — numbered blocks key
  off an ID prefix (`::: {#thm-foo name="…"}`, prefixes thm/lem/cor/prp/cnj/def/exm/exr),
  unnumbered off a class (`::: {.proof}` / `.remark` / `.solution`) — and LaTeX
  envs (`\begin{theorem}[title]`) in
  [tex-callout-plugin.ts](src/editor/tex-callout-plugin.ts) both feed the shared
  [callout-core.ts](src/editor/callout-core.ts) (numbering, label widget,
  collapsed-fence decorations). Each plugin is only a line-scanner —
  no Lezer node — so interior math/markup keeps rendering. The hosts stay
  identical *because* the core is shared: add new callout behavior there, not in
  one syntax. Recognised tex envs are disjoint from tex-math's
  `MATH_ENVIRONMENTS`, so `equation`/`align` are never callouts.
- **Beamer frames** render as slide cards
  ([tex-frame-plugin.ts](src/editor/tex-frame-plugin.ts) +
  [src/styles/slide.css](src/styles/slide.css)): per-line classes stack into a
  box the way callouts do, the fences collapse, and the slide number is a
  `::after` reading `data-slide` (no height, no caret surface — the fenced
  code block's language chip trick). Three things are load-bearing:
  the card outline is drawn with INSET BOX-SHADOWS, not borders, so a nested
  callout's own `border-left` accent doesn't replace the card's left edge;
  `frameBlockAt` is the `calloutBlockAt` twin that carries the card's SIDE
  edges through a display-math block widget (skip it and every `\[…\]` breaks
  the box open); and `isBeamerDoc` gates the whole thing, so an `article` that
  happens to use a `frame` environment gets nothing.
  **The `\end{frame}` row is the card's foot** — its text is hidden but the row
  stays, and it always carries `cm-slide-bottom`. Don't "optimise" that back
  into collapsing the row and closing the card on the last body row: a frame
  ending in a block has `\end{block}` collapsed by the callout plugin and
  `\end{frame}` collapsed by this one, so every candidate row is gone and the
  card silently never closes; and a nested callout row is inset on both sides,
  so a foot drawn there is narrower than the sides it joins. Adding a type to
  `LABELS` without an accent/tint pair in callout.css renders it invisible
  (both declarations resolve to an undefined var and are dropped) — the block
  family shipped that way for an hour; `css-guardrails.test.ts` now pins it. Both title syntaxes
  (`\begin{frame}{T}{S}` and `\frametitle`/`\framesubtitle`) must keep
  producing the same band — the parity is pinned in the browser harness, not
  in jsdom, because it is a measured height. `\pause`, overlay specs
  (`<2->`) and `columns` are deliberately left as raw source; that is a
  decision, not a gap. beamer's `block`/`alertblock`/`exampleblock` are plain
  callout types, so they take their title in a BRACE argument — the widened
  regex is scoped to those three names, or `\begin{minipage}{0.45\textwidth}`
  becomes a callout.
- **Don't re-enable native `::selection`** — CM6's layered selection (themed
  with `Prec.highest` in [src/editor/theme.ts](src/editor/theme.ts)) is the
  only intended paint; native `::selection` draws opaque over math widgets.
- **Don't remove `contain: inline-size`** from `.cm-{tex-,}math-display`
  ([src/styles/editor.css](src/styles/editor.css), [math.css](src/styles/math.css)) —
  KaTeX descendants would otherwise force `.cm-content` wider than the
  viewport and surface horizontal scrollbars on numbered equations.
- **NO vertical margins on lines or block widgets inside `.cm-content`.**
  CM6 measures element boxes; margins are invisible to its height map, so
  every margined block desyncs the map from the DOM for the whole document
  below it — `posAtCoords` then resolves clicks and Up/Down several lines off
  (live-debugged: callout-edge margins drifted the map ~24px and sent the
  caret five rows away). All vertical spacing must be PADDING. The caret /
  click behavior is verifiable in a real browser with the Playwright harness
  pattern (mount the bundle, drive real keys, read the selection).
- The default snippet set ([assets/latex.hsnips](assets/latex.hsnips)) is
  copied verbatim into each host's bundle — it is the single source of truth
  for default snippets.
