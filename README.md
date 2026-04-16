# Chalk-TeX

Live math preview for `.tex` files, rendered inline via KaTeX. Sibling project
to [Chalk](https://github.com/raphaelhuleux/chalk) — shares the architecture,
ships a narrower feature set: math widgets only, no prose preview.

## What it does

Open a `.tex` file. Math delimited by `$…$`, `$$…$$`, `\(…\)`, `\[…\]`, or a
`\begin{equation}…\end{equation}`-style environment renders in place as KaTeX.
Put your cursor inside the math region and the raw LaTeX comes back so you can
edit it.

Supported math environments (with starred variants):
`equation`, `align`, `gather`, `multline`, `alignat`, `eqnarray`.

LaTeX syntax highlighting for the non-math parts is delegated to CodeMirror's
`stex` stream language.

## What it deliberately doesn't do

No compile-to-PDF. No side-panel preview. No bibliography management. No
command completion beyond CM6 defaults. This is meant to sit alongside
[LaTeX Workshop](https://github.com/James-Yu/LaTeX-Workshop) — not replace it.
Workshop handles compilation; Chalk-TeX handles live math inside your source.

## Install

```bash
npm install
npm run build
npm run package
code --install-extension chalk-tex-0.1.0.vsix
```

`.tex` files then open in Chalk-TeX by default. `Cmd+:` opens VS Code's
*Reopen Editor With…* picker if you want to switch to the plain text editor.

## License

MIT
