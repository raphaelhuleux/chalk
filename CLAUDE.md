# Chalk-TeX

Live math preview for `.tex` files, packaged as a VS Code custom editor
extension. Sibling to [Chalk](../chalk/) (markdown editor); shares the same
architecture minus the markdown-specific bits.

## Branch status (2026-04-16)

Freshly scaffolded. Ports the Chalk custom-editor shell (Node-side provider,
webview HTML, CSP, bidirectional sync, KaTeX cache, VS Code theme mapping)
and replaces the markdown parser + live-preview with a LaTeX math scanner.

Not yet installed as a `.vsix`; smoke test pending.

## What's different from Chalk

| Component | Chalk (markdown) | Chalk-TeX |
|---|---|---|
| Language | `@codemirror/lang-markdown` + `@lezer/markdown` | `@codemirror/legacy-modes/mode/stex` stream language |
| Math detection | `mathSyntax` extension → lezer `InlineMath`/`DisplayMath` nodes | Regex-free character walker ([tex-math.ts](src/webview/editor/tex-math.ts)) |
| Live preview | headings / bold / italic / etc. via syntax-tree iteration | **only math** (no prose decorations by design) |
| Theme-token reading | heading.N.markdown → `--chalk-heading-*` CSS vars | not used — no tokens rendered |
| File selector | `*.md`, viewType `chalk.markdownEditor` | `*.tex`, viewType `chalk-tex.texEditor` |

## Architecture (shared with Chalk)

Extension host (Node) ↔ webview (Chromium sandbox) via `postMessage`:
- `extension → webview`: `init({text})`, `update({text})`
- `webview → extension`: `edit({text})`, `open-external({url})`

Sync strategy: eager full-text replace. `isApplyingOwnEdit` flag prevents
`edit → WorkspaceEdit → onDidChangeTextDocument → update → edit` loops.

Activation: `.tex` files open in Chalk-TeX by default (`priority: "default"`
on the `customEditors` contribution). `Cmd+:` uses VS Code's built-in
*Reopen Editor With…* picker — no custom keybinding machinery.

## Core logic — the one genuinely new piece

[src/webview/editor/tex-math.ts](src/webview/editor/tex-math.ts) exports
`scanMathRegions(text, offset)` — a pure function that walks a LaTeX source
string and returns non-overlapping math regions. Handles:

- `$…$`, `$$…$$`, `\(…\)`, `\[…\]`
- `\begin{env}…\end{env}` for env in MATH_ENVIRONMENTS
- `%` line comments (skipped)
- `\$` literal dollar and any other `\x` escape

The ViewPlugin scans only visible ranges on every update, cursor-aware:
regions containing the cursor keep their raw source visible; everything
else renders as a `MathWidget` that calls `KaTeXCache.render()`.

## Guardrails

- Do not add markdown-style live-preview (bold, italic, headings). That's
  Chalk's job; Chalk-TeX is math-only by design.
- Do not add LaTeX compilation, bibliography, or any feature
  [LaTeX Workshop](https://github.com/James-Yu/LaTeX-Workshop) already
  provides. Chalk-TeX sits *alongside* Workshop.
- Theme-token reading (the heading-color path in Chalk) does not apply
  here. If a theme-aware math styling decision comes up later, add it
  deliberately — don't port code across just because it's there.

## Build & install

```bash
npm install
npm run build          # esbuild: two entry points (extension + webview)
npm run package        # runs build + vsce package → chalk-tex-0.1.0.vsix
code --install-extension chalk-tex-0.1.0.vsix
```
