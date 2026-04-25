# Chalk

Live-preview editor for `.tex` and `.md` files with first-class math
support, packaged as a VS Code custom editor extension. Two `viewType`s
(`chalk.texEditor`, `chalk.markdownEditor`) share one host shell, KaTeX
cache, theme reader, and hsnips snippet engine; per-language CodeMirror
extensions diverge in `setup.ts`.

## Branch status (2026-04-16)

Freshly scaffolded. Ports the Chalk custom-editor shell (Node-side provider,
webview HTML, CSP, bidirectional sync, KaTeX cache, VS Code theme mapping)
and replaces the markdown parser + live-preview with a LaTeX math scanner.

Not yet installed as a `.vsix`; smoke test pending.

## What's different from Chalk

| Component | Chalk (markdown) | Chalk (tex) |
|---|---|---|
| Language | `@codemirror/lang-markdown` + `@lezer/markdown` | `@codemirror/legacy-modes/mode/stex` stream language |
| Math detection | `mathSyntax` extension → lezer `InlineMath`/`DisplayMath` nodes | Regex-free character walker ([tex-math.ts](src/webview/editor/tex-math.ts)) |
| Live preview | headings / bold / italic / etc. via syntax-tree iteration | **only math** (no prose decorations by design) |
| Theme-token reading | heading.N.markdown → `--chalk-heading-*` CSS vars | not used — no tokens rendered |
| File selector | `*.md`, viewType `chalk.markdownEditor` | `*.tex`, viewType `chalk.texEditor` |

## Architecture (shared with Chalk)

Extension host (Node) ↔ webview (Chromium sandbox) via `postMessage`:
- `extension → webview`: `init({text})`, `update({text})`
- `webview → extension`: `edit({text})`, `open-external({url})`, `command({id})`

The `command` message is whitelisted (`WEBVIEW_ALLOWED_COMMANDS`) to avoid
turning into an arbitrary-command dispatcher. Currently: `chalk.build`.

Sync strategy: eager full-text replace. `isApplyingOwnEdit` flag prevents
`edit → WorkspaceEdit → onDidChangeTextDocument → update → edit` loops.

Activation: `.tex` files open in Chalk by default (`priority: "default"`
on the `customEditors` contribution). `Cmd+:` uses VS Code's built-in
*Reopen Editor With…* picker — no custom keybinding machinery.

LaTeX Workshop bridge: `chalk.build` (`Cmd+Alt+B`) in
[src/extension/workshop-bridge.ts](src/extension/workshop-bridge.ts).
**Currently non-functional** — see [KNOWN_ISSUES.md](KNOWN_ISSUES.md).
The bridge opens the doc in a native side-column editor with
`preserveFocus: true` intending to populate `activeTextEditor`, but
Workshop's build still fails to resolve the root. Code left in place as
a starting point for future debugging.

## Core logic — the one genuinely new piece

[src/webview/editor/tex-math.ts](src/webview/editor/tex-math.ts) exports
`scanMathRegions(text, offset)` — a pure function that walks a LaTeX source
string and returns non-overlapping math regions. Handles:

- `$…$`, `$$…$$`, `\(…\)`, `\[…\]`
- `\begin{env}…\end{env}` for env in MATH_ENVIRONMENTS
- `%` line comments (skipped)
- `\$` literal dollar and any other `\x` escape

Exposed as a `StateField` (not a `ViewPlugin`): CM6 forbids block replace
decorations from view plugins, and display math needs `block: true`.
The field re-scans the whole doc on each transaction (cheap — O(n) walker +
KaTeX cache), cursor-aware: regions containing the cursor keep their raw
source visible; everything else renders as a `MathWidget` that calls
`KaTeXCache.render()`.

## Guardrails

- Do not add markdown-style live-preview (bold, italic, headings). That's
  the markdown editor's job; the tex editor is math-only by design.
- Do not add LaTeX compilation, bibliography, or any feature
  [LaTeX Workshop](https://github.com/James-Yu/LaTeX-Workshop) already
  provides. Chalk sits *alongside* Workshop.
- Theme-token reading: only for syntax-highlight colors (see
  [src/extension/theme-reader.ts](src/extension/theme-reader.ts)).
  The extension host parses the active theme's JSON `tokenColors`,
  resolves prefix matches against a curated list of LaTeX scopes,
  posts `--chalk-syntax-*` CSS vars to the webview, and re-posts
  on `onDidChangeActiveColorTheme`. Hex fallbacks live in
  [syntax-highlight.ts](src/webview/editor/syntax-highlight.ts). Do
  not expand this pipeline to math rendering without a concrete need.

## Build & install

```bash
npm install
npm run build          # esbuild: two entry points (extension + webview)
npm run package        # runs build + vsce package → chalk-0.1.0.vsix
code --install-extension chalk-0.1.0.vsix
```
