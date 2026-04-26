# Chalk

Live-preview editor for `.tex` and `.md` files, with KaTeX math rendering and HyperSnips-style snippet expansion. Two custom-editor `viewType`s share one host shell, KaTeX cache, theme reader, and snippet engine.

## What it does

Open a `.tex` or `.md` file. Math delimited by `$…$`, `$$…$$`, `\(…\)`, `\[…\]`, or a `\begin{equation}…\end{equation}`-style environment renders in place as KaTeX. Put your cursor inside the math region and the raw LaTeX comes back so you can edit it.

Supported math environments (with starred variants): `equation`, `align`, `gather`, `multline`, `alignat`, `eqnarray`.

**LaTeX (`.tex`)** — `stex` syntax highlighting, autocomplete for `\begin{…}` environments and common commands (`\frac`, `\alpha`, Greek letters, decorations, accents). To compile, hit `Cmd+Shift+;` to switch to VS Code's plain text editor and use LaTeX Workshop from there — Chalk doesn't bridge the build command.

**Markdown (`.md`)** — bold/italic/strikethrough/code/link decorations, heading colors derived from the active VS Code theme, horizontal rules, blockquotes, and inline+display math.

**Snippets (both)** — ships with a curated `latex.hsnips` for math typing (`fr` → `\frac{}{}`, `sr` → `^{2}`, `cb` → `^{3}`, etc.). Override or extend by dropping your own `~/.config/hsnips/latex.hsnips` (and optionally `markdown.hsnips`) — your file replaces the bundled default. The engine is a self-contained CM6 port of the HyperSnips file format; inline JS blocks (\`\`…\`\`) are parsed but discarded, only static-body snippets are supported. The `draivin.vscode-hsnips` extension is **not** required.

## What it deliberately doesn't do

No compile-to-PDF. No side-panel preview. No bibliography management. This is meant to sit alongside [LaTeX Workshop](https://github.com/James-Yu/LaTeX-Workshop) — not replace it. Workshop handles compilation; Chalk handles live math inside your source.

## Install

```bash
npm install
npm run build
npm run package
code --install-extension chalk-0.2.0.vsix --force
```

`.tex` and `.md` files open in Chalk by default. `Cmd+Shift+;` opens VS Code's *Reopen Editor With…* picker if you want to switch to the plain text editor.

## License

MIT
