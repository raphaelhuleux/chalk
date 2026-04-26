# Chalk

Live-preview editor for `.tex` and `.md` files, with KaTeX math rendering and HyperSnips-style snippet expansion. Two custom-editor `viewType`s share one host shell, KaTeX cache, theme reader, and snippet engine.

## What it does

Open a `.tex` or `.md` file. Math delimited by `$…$`, `$$…$$`, `\(…\)`, `\[…\]`, or a `\begin{equation}…\end{equation}`-style environment renders in place as KaTeX. Put your cursor inside the math region and the raw LaTeX comes back so you can edit it.

Supported math environments (with starred variants): `equation`, `align`, `gather`, `multline`, `alignat`, `eqnarray`.

**LaTeX (`.tex`)** — `stex` syntax highlighting, autocomplete for `\begin{…}` environments and common commands (`\frac`, `\alpha`, Greek letters, decorations, accents), and `Cmd+Alt+B` for LaTeX Workshop's build command (currently non-functional — see `KNOWN_ISSUES.md`).

**Markdown (`.md`)** — bold/italic/strikethrough/code/link decorations, heading colors derived from the active VS Code theme, horizontal rules, blockquotes, and inline+display math.

**Snippets (both)** — reads `~/.config/hsnips/latex.hsnips` (and `markdown.hsnips` for `.md`) using a self-contained CM6 port of the HyperSnips file format. Inline JS blocks (\`\`…\`\`) are parsed but discarded; only static-body snippets are supported. The `draivin.vscode-hsnips` extension is **not** required.

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
