# Chalk

Live-preview editor for `.tex` and `.md` files with first-class math support, packaged as a VS Code custom editor extension.

Two `viewType`s share one host shell, KaTeX cache, theme reader, and hsnips snippet engine; per-language CodeMirror extensions diverge in [setup.ts](src/webview/editor/setup.ts).

## Status (2026-04-26)

Merged from chalk-tex (LaTeX-only) and the archived chalk-md. Tex math
preview works. Markdown headings + math + live-preview work. Hsnips
shared across both. **No build bridge** — to compile a `.tex` file,
hit `Cmd+Shift+;` to switch to the plain text editor and use LaTeX
Workshop from there. The webview-side build path (formerly `chalk.build`
+ `Cmd+Alt+B`) was removed because Workshop's root detection depends
on `activeTextEditor` which is undefined when a `CustomTextEditorProvider`
owns the tab.

## Architecture

Extension host (Node) ↔ webview (Chromium sandbox) via `postMessage`:

- `extension → webview`: `init({text, language})`, `update({text})`,
  `theme-colors({colors})`, `heading-colors({colors})` (md only),
  `hsnips({content})`
- `webview → extension`: `ready`, `edit({text})`,
  `open-external({url})`

Sync strategy: eager full-text replace. `isApplyingOwnEdit` flag prevents
edit→WorkspaceEdit→onDidChangeTextDocument→update→edit loops.

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

## Build & install

```bash
npm install
npm run build          # esbuild: extension + webview
npm run package        # produces chalk-X.Y.Z.vsix
code --install-extension chalk-0.3.0.vsix --force
```

Test fixtures: [test/fixtures/smoke.tex](test/fixtures/smoke.tex),
[test/fixtures/smoke.md](test/fixtures/smoke.md).
