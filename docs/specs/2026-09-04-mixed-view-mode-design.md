# Mixed view mode

Date: 2026-09-04. Status: approved design, not yet planned or implemented.

## Purpose

Chalk has two ways to look at a document: Preview, where markdown and LaTeX syntax is concealed and revealed under the caret, and Source, where nothing is rendered.
The reveal reflow in Preview is sometimes clunky to edit through.
Mixed is a third stop on the cycle: syntax stays visible and styled, blocks keep their box styling, and only the replaced-whole constructs (math, images, tables) stay rendered with their reveal-on-caret behavior.

## Decisions

- Math keeps its Preview behavior in Mixed, including reveal on caret.
- Images and tables keep their Preview behavior in Mixed.
- Inline constructs (bold, italic, code, strikethrough, highlight, links, `\textbf`, `\emph`, refs, cites, footnotes, sections, `@` cross-references) show their syntax and keep their styling, with no reveal logic.
- Block constructs (Quarto callouts, LaTeX theorem-family environments, Beamer frames and blocks, LaTeX lists) keep their box styling but show their fences as raw, dimmed lines.
- The synthesized label and number of a numbered callout is a floating chip at the right edge of the top row, not a widget and not an extra row.
- Lists show a raw `\item` in the marker's accent color, with no marker widget and no numbering.
- The mode is a per-editor state seeded from a host-owned default. Cmd+: cycles the current editor only. The settings pane sets the default.
- Labels: Preview, Mixed, Source. Cycle order: Preview, Mixed, Source, then back to Preview.
- Implementation approach: the existing builders take a `conceal` option; Mixed is "always revealed". No structural split of hide from style in this round.

## 1. Mode model

`EditorConfig` gains `viewMode: 'preview' | 'mixed' | 'source'`, default `preview`, sanitized with `oneOf` like `editingMode`.
The engine keeps a per-editor `viewModeField` seeded from the config on init.
Cmd+: dispatches the next mode into the field and reconfigures `previewCompartment` with that language's set for the new mode.
An `editor-config` message whose `viewMode` differs from the one last received resets the field and the compartment to the new default in every editor that receives it.
The boolean `sourceModeField` in setup.ts is removed; every reader (the vertical-motion keymaps) reads `viewModeField` instead.
The `HostPort` message shapes do not change. The config payload is already typed `unknown`, so this is a config-field addition, not a protocol change.

## 2. Engine plugin sets

Each language defines three extension sets for `previewCompartment`.

Markdown:

- Preview: today's `mdPreview`, unchanged.
- Mixed: `mathPlugin()`, `tablePlugin()`, `calloutPlugin({ conceal: false })`, `livePreviewPlugin({ conceal: false })`, `mdCrossrefPlugin({ conceal: false })`, `frontmatterDimExtension()`, `codeBlockPlugin()`.
- Source: empty.

LaTeX:

- Preview: today's `texPreview`, unchanged.
- Mixed: `texFramePlugin({ conceal: false })`, `texCalloutPlugin(texListLineCollapsed, { conceal: false })`, `texListPlugin({ conceal: false })`, `texMathPlugin()`, `texImagePlugin()`.
  `texConcealPlugin({ conceal: false })`, which dims the command prefix and closing brace of every recognised command instead of hiding them.
  `texDecorationsPlugin` outside the compartment keeps styling the arguments.
- Source: empty.

Inside each builder the option is one branch.
Every `Decoration.replace` emit goes through a `hide()` helper that is a no-op when `conceal` is false.
Every reveal predicate is read through a wrapper that returns false when `conceal` is false, and the `hide()` helper emits a dimmed `cm-syntax-dim` mark instead of a replace, because markdown's revealed state carries no styling marks of its own.
The image branch of `md-live-preview.ts` is exempt: it keeps its replace and its `revealReplacedSource` in both modes.
Inline delimiters (`**`, `_`, `` ` ``, `~~`, `==`, `[`, `](…)`, `\cmd{`, `}`) get a `cm-syntax-dim` mark at reduced opacity so they read as syntax rather than text.
With `conceal` false the `texListLineCollapsed` callback always returns false, since no list fence collapses.

## 3. Blocks, fences and the chip

With `conceal` false, `callout-core.ts` emits its line classes on every row from the open fence to the close fence, both fences included, so the card tint and the accent bar cover the fence lines.
Fence rows get the `cm-syntax-dim` mark over their text.
The top row carries a `data-callout` attribute (`Decoration.line({ attributes })`) holding the label and number, for example `Theorem 1`.
The chip is drawn by `.cm-line.cm-callout-top[data-callout]::after` reading `attr(data-callout)`, right-aligned, no height and no caret surface, the slide-number mechanism in slide.css.
Unnumbered types (proof, remark, solution, Beamer blocks) carry no attribute and draw no chip.
The Quarto heading-title line (`## Title` as the first body line) is not folded; it stays a heading inside the card.
A fence line long enough to wrap runs under the chip. This is accepted, as it already is for the slide number.

LaTeX titles are styled by marks on the argument with the existing classes, so the band keeps its look while the command stays visible:

- `\begin{theorem}[Pythagoras]`: the fence is dimmed and `[Pythagoras]` is marked `cm-callout-title`.
- `\begin{frame}{Title}{Subtitle}`: the row keeps `cm-slide-band` and `cm-slide-top`; `\begin{frame}{` and the braces are dimmed; the arguments are marked `cm-tex-frametitle` and `cm-tex-framesubtitle`.
- `\frametitle{…}` and `\framesubtitle{…}` on their own lines get the identical treatment, so both title syntaxes keep producing the same band.
  Parity between the two title syntaxes in Mixed is class parity, not height: the brace form is one raw row and the command form two or three.
- The `\end{frame}` row stays the card's foot with its text dimmed rather than hidden.
- Beamer `block`, `alertblock`, `exampleblock`: the brace argument is marked with the label styling; no chip.

Lists: `\begin{enumerate}` and `\end{enumerate}` are raw and dimmed, `\item` is marked `cm-tex-item-marker` for its color, and `\item[custom]` is unchanged.
The hanging indent still applies.

Sketch of a Quarto theorem in Mixed, caret elsewhere:

```
┃ ::: {#thm-pyth name="Pythagoras"}              Theorem 1 ┃
┃ In a right triangle, $a^2 + b^2 = c^2$.                   ┃
┃ :::                                                        ┃
```

## 4. Motion, gestures and the caret spec

In Mixed the frame, callout and list fence-stop keymaps are inactive, and the fence reveals never fire, since nothing is hidden.
The math and table stop keymaps stay active, and `texVerticalArrowKeymap` and `mdVerticalArrowKeymap` stay active for the snap out of math and image widgets.
The pointer-gesture tracker stays registered because math and images still reveal.
The fence-stop keymaps take an `active` predicate and fire only in Preview.
`docs/specs/2026-08-23-caret-and-reveal-semantics.md` gains R-X2 next to R-X1: in Mixed only replaced-whole constructs (math, images, tables) have a reveal window; every other construct is permanently in its revealed state and every other motion is default motion.

## 5. Hosts

iOS and Mac:

- `Preferences.swift` gains `ViewMode: String, CaseIterable` with `preview`, `mixed`, `source`, a `chalk.viewMode` defaults key, `next`, a title and a symbol, and `configPayload` producing `{"viewMode": rawValue}`.
- The settings pane gains a "Default view mode" row with the three choices.
- A change to the default pushes the config to all open tabs, the way `setEditingMode` broadcasts today.
- Mac gets a View Mode submenu with the three direct picks, each setting the default; no cycle item, since Cmd+: cycles one editor and a host cycle would move the default.
- Cmd+: keeps working inside the editor with no host involvement.
- The iOS payload carries both `editingMode` and `viewMode` in one object, because editor-core sanitizes the message as a whole and a missing field falls back to its default.

VS Code:

- `package.json` contributes `chalk.viewMode` with the three values, default `preview`.
- `chalk-editor-provider.ts` reads it into the `editor-config` payload and re-sends on configuration change.

Neither host learns the current per-editor mode.
No footer indicator in this round.

## 6. Testing

Vitest (jsdom):

- A decoration snapshot per construct in each mode, for both languages.
- Mixed emits zero `replace` ranges outside math, images and tables.
- The chip attribute lands on the top row with the right label and number, and never on an unnumbered type.
- Both frame title syntaxes emit the same title and subtitle marks.
- `sanitizeEditorConfig` accepts the three values and falls back to `preview`.
- `mount.ts`: the cycle order, the per-editor scope, and the reset on a changed default.
- The `css-guardrails` test pins that `cm-syntax-dim`, `cm-crossref-key`, `cm-tex-item-source` and the chip rule exist.

Browser harness (`pnpm test:browser`):

- A Mixed lane for the section 4 rules: Up/Down through a callout is default motion, math still stops and reveals, an image still reveals on click.
- Class parity of the two frame title syntaxes in Mixed (jsdom).

Swift:

- ChalkKit round-trips the new config field.
- ChalkTests covers `ViewMode.next` and the broadcast to all tabs.

## Out of scope

- A structural split of hide from style on the markdown side (Approach 2 in the interview). Revisit if Source mode should gain styling.
- A footer or tab-strip indicator of the current per-editor mode.
- Numbering for `\item` in Mixed.
