# Chalk

Live-preview editor for `.tex` and `.md` files with first-class math support, packaged as a VS Code custom editor extension.

Two `viewType`s share one host shell, KaTeX cache, theme reader, and hsnips snippet engine; per-language CodeMirror extensions diverge in [setup.ts](src/webview/editor/setup.ts).

## Status (2026-04-28)

v0.4.0, published to the VS Code Marketplace as
`RaphalHuleux.chalk-math` (GitHub: `raphaelhuleux/chalk`). End-users
see "Chalk" everywhere — `displayName` drives the marketplace listing
title, search results, install dialog. The technical `name` field is
`chalk-math` only because plain `chalk` was already taken on the
marketplace. The publisher ID `RaphalHuleux` was auto-derived by
Microsoft from the account display name with diacritics stripped
(`Raphaël` → `Raphal`); it's immutable, so don't "fix" the case in
`package.json.publisher`.

Tex math, markdown headings, and hsnips work in both editors. **No
build bridge** — to compile a `.tex` file, hit `Cmd+Shift+;` to switch
to the plain text editor and use LaTeX Workshop from there. The
webview-side build path (formerly `chalk.build` + `Cmd+Alt+B`) was
removed because Workshop's root detection depends on `activeTextEditor`,
which is undefined when a `CustomTextEditorProvider` owns the tab.

Known platform gap: Windows is untested. Marketplace listing is live
on macOS / Linux. v0.4 / v1.0 should verify Windows before relying
on it.

## Architecture

Extension host (Node) ↔ webview (Chromium sandbox) via `postMessage`:

- `extension → webview`: `init({text, language})`, `update({text})`,
  `theme-colors({colors})`, `heading-colors({colors})` (md only),
  `hsnips({content})`
- `webview → extension`: `ready`, `edit({text})`,
  `open-external({url})`

Sync strategy: host → webview updates apply as minimal text diffs
([text-diff.ts](src/webview/utils/text-diff.ts)) so CM6 preserves
cursor and viewport across autocomplete / snippet edits. Webview →
host edits send the full new text. `isApplyingOwnEdit` depth counter
prevents the edit ↔ update loop.

Activation: `.tex` → `chalk.texEditor`, `.md` → `chalk.markdownEditor`,
both `priority: "default"`. `Cmd+Shift+;` reopens with VS Code's picker.

## Language seam

[src/extension/languages/](src/extension/languages/) holds one
`LanguageProfile` per file type:

- `tex.ts` — viewType, latex.hsnips loader, tex scope candidates
- `markdown.ts` — viewType, no commands, latex+markdown hsnips loader, empty scopes (md uses heading-color channel separately)

The provider class is generic over the profile. The webview's [setup.ts](src/webview/editor/setup.ts) branches on the `language` field in the init message: `tex` arm uses `stex` + `texMathPlugin` + tex syntax highlight + `latexCompletionExtension`; `md` arm uses `markdown(...)` + `mathPlugin` + `livePreviewPlugin` in a preview compartment.

The shared hsnips engine ([hsnips-plugin.ts](src/webview/editor/hsnips-plugin.ts)) takes an `isInMathContext` callback at construction time — tex passes `isInMathContextTex` (regex/character walker), md passes `isInMathContextMd` (lezer-tree query). All trigger matching, body parsing, tab-stops are language-agnostic.

## Hsnips

Standalone implementation of the HyperSnips file format (no dependency on the `draivin.vscode-hsnips` extension). The engine is fully self-contained in CM6 — VS Code's native snippet machinery doesn't run inside custom-editor webviews. Inline JS blocks (\`\`…\`\`) in `.hsnips` files are parsed but discarded; only static-body snippets are supported.

Resolution order: (1) `hsnips.hsnipsPath` setting, (2) `~/.config/hsnips/`, (3) the bundled default at [assets/latex.hsnips](assets/latex.hsnips). User files fully override; we don't merge. The default is embedded as a string literal at build time via esbuild's `text` loader (see [esbuild.config.js](esbuild.config.js)) — the .vsix doesn't carry an extra file, the bundle just grows by the snippet file's size (~23KB).

## Guardrails

- Markdown live-preview shouldn't add features beyond what chalk-md
  shipped (headings, bold, italic, link, code, strikethrough, hr,
  blockquote, math). Don't expand to tables, footnotes, MDX, etc.
  without a concrete need.
- Don't add LaTeX compilation, bibliography, or other features that
  [LaTeX Workshop](https://github.com/James-Yu/LaTeX-Workshop) provides.
- Theme-color reading: tex uses syntax-tag scopes
  ([theme-reader.ts](src/extension/theme-reader.ts)); md uses heading-N
  scopes ([markdown-heading-colors.ts](src/extension/markdown-heading-colors.ts)).
  The two paths are intentionally separate — they output different CSS
  var families and serve different decoration systems.
- Don't replace the minimal-diff sync with full-text replace. CM6
  loses cursor/viewport on every autocomplete or snippet edit if you do.
- Don't re-enable native `::selection` in the webview. CM6's layered
  selection (themed in [theme.ts](src/webview/editor/theme.ts) with
  `Prec.highest`) is the only intended paint; native ::selection
  draws opaque on math widgets while focused.
- Don't remove `contain: inline-size` from `.cm-{tex-,}math-display`
  ([editor.css](src/webview/styles/editor.css), [math.css](src/webview/styles/math.css)).
  KaTeX descendants would otherwise force `.cm-content` wider than
  the viewport and surface horizontal scrollbars on numbered equations.

## Build & install

```bash
npm install
npm run build          # esbuild: extension + webview
npm run package        # produces chalk-X.Y.Z.vsix
code --install-extension chalk-math-0.3.2.vsix --force
```

Test fixtures: [test/fixtures/smoke.tex](test/fixtures/smoke.tex),
[test/fixtures/smoke.md](test/fixtures/smoke.md).
