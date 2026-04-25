# Chalk

Live math preview for `.tex` and `.md` files, rendered inline via KaTeX. Also allows for snippets and fast math writing, similar to `hypersnip`.

## What it does

Open a `.tex` or `.md` file. Math delimited by `$…$`, `$$…$$`, `\(…\)`, `\[…\]`, or a
`\begin{equation}…\end{equation}`-style environment renders in place as KaTeX.
Put your cursor inside the math region and the raw LaTeX comes back so you can edit it.

Supported math environments (with starred variants):
`equation`, `align`, `gather`, `multline`, `alignat`, `eqnarray`.

LaTeX syntax highlighting for the non-math parts is delegated to CodeMirror's `stex` stream language.

## What it deliberately doesn't do

No compile-to-PDF. No side-panel preview. No bibliography management. No command completion beyond CM6 defaults. This is meant to sit alongside [LaTeX Workshop](https://github.com/James-Yu/LaTeX-Workshop) — not replace it.
Workshop handles compilation; Chalk handles live math inside your source.

## Install

```bash
npm install
npm run build
npm run package
code --install-extension chalk-0.1.0.vsix
```

`.tex` files then open in Chalk by default. `Cmd+:` opens VS Code's
*Reopen Editor With…* picker if you want to switch to the plain text editor.

## License

MIT
