# Chalk

Chalk is a Markdown and LaTeX editor for writing mathematics.
Your document renders where you type it: equations, numbered equations, theorems and proofs, callouts and Beamer slides, all in the same pane as the source.
Chalk compiles the pdf with your own TeX, pandoc or Quarto and shows it beside the text.

![Chalk for Mac: a Markdown note with a theorem, a proof, numbered equations, cross-references and a callout](docs/images/mac-hero.png)

Chalk comes in two forms, built on one editor engine:

- **Chalk for Mac**: a native app with tabs, a folder sidebar, an outline panel and a PDF panel.
- **Chalk for VS Code**: the same editor for `.tex`, `.md` and `.qmd` files, compatible with LaTeX Workshop.

## Features

### Math as you type

![Typing in Chalk: each formula renders as soon as the cursor leaves it](docs/images/live-preview.gif)

Inline and display math render with KaTeX as soon as the cursor leaves them.
Move back in and you edit the source; there is no separate preview to keep in sync.

### Numbered equations and cross-references

`equation` and `align` blocks are numbered as you write, and references point at them:

- LaTeX: `\label{eq:euler}` and `\eqref{eq:euler}`.
- Markdown and Quarto: `$$ … $$ {#eq-euler}` and `@eq-euler`.

### Theorems, proofs and callouts

Theorem-like environments render as cards with their number and title.

- **LaTeX:** `\begin{theorem}[Euler equation]`, `lemma`, `corollary`, `proposition`, `definition`, `remark`, `proof` and the rest of the family.
- **Markdown and Quarto:** fenced divs in Quarto's syntax.
  - Numbered blocks: `::: {#thm-euler}`, `#lem-`, `#cor-`, `#prp-`, `#def-`, `#exm-`.
  - Unnumbered blocks: `::: {.proof}`, `.remark`, `.solution`.
  - Callouts: `::: {.callout-note}`, `tip`, `warning`, `important`, `caution`.

![A .tex file with a theorem, a proof, numbered equations and the outline panel](docs/images/mac-tex.png)

### Beamer slides

Each `frame` becomes a numbered slide card with its title, and `block`, `alertblock`, `exampleblock` and theorems render inside it.

![A Beamer deck shown as slide cards](docs/images/mac-beamer.png)

### Compile and preview the PDF (Mac)

- **Cmd+R** compiles the document and shows the PDF in a panel beside the text; **Cmd+S** recompiles.
- **SyncTeX both ways:** Cmd-click in the PDF jumps to the source line, and **Option+Cmd+J** jumps from the caret to the PDF.
- **Multi-file projects:** saving a chapter compiles its root file, found from a `% !TEX root` comment, the `\input`/`\include` graph or the last build's `.fls`.
- **LaTeX:** latexmk when installed; otherwise pdflatex, xelatex or lualatex with bibtex or biber and the extra passes; or tectonic.
- **Markdown and Quarto:** Quarto or pandoc, your choice in Settings.
- **A default header:** a `.md` file without a YAML header can compile with one you set once (fonts, margins, author, date). Your file is not changed.
- **Errors:** listed under the PDF with file and line; a click jumps there.

### Snippets

![Typing dm, lim, ooo, 1/, sum and ;m expands to a full align block](docs/images/snippets.gif)

HyperSnips-style triggers expand as you type.
`dm` opens an `align` block, `lim` gives `\lim_{n \to \infty}`, `1/` starts a fraction, `;m` is `\mu`, and Tab jumps to the next field.
The default set covers Greek letters, operators, accents and environments, and Chalk reads your own `.hsnips` files unchanged.

### Markdown and Quarto

Headings, lists, tables you edit in place, images (centred when they stand alone), and Mermaid diagrams drawn under their source.

![A Markdown note with a Mermaid flowchart rendered under its source](docs/images/mac-mermaid.png)

### A quiet place to write

- **Three view modes:** preview, mixed (markup visible but dimmed, math and images still rendered) or plain source.
- **Writing modes:** zen, typewriter and focus.
- **Outline:** sections and environments in a panel, with a word count.
- **Colour themes:** Atom, Ink, Catppuccin and LaTeX, each in light and dark.

![The same Markdown note in mixed view](docs/images/mac-mixed.png)

### In VS Code

![The Chalk editor showing a .tex file inside VS Code](docs/images/vscode.png)

The extension opens `.tex`, `.md` and `.qmd` files in the Chalk editor and builds LaTeX projects with your LaTeX Workshop recipe:

- **Build on save:** the root of a multi-file project is found on its own.
- **Cmd+Alt+B** builds and **Cmd+Alt+V** opens LaTeX Workshop's PDF viewer.
- **Click in the PDF:** jumps back into the Chalk editor.
- **Not yet:** jumping from the source to the PDF. LaTeX Workshop only offers it from its own text editor.

## Requirements for compiling

Chalk uses the tools already on your Mac and finds them on your shell's `PATH`:

- **LaTeX:** a TeX distribution such as [MacTeX](https://tug.org/mactex/) (or BasicTeX), or [tectonic](https://tectonic-typesetting.github.io).
- **Markdown:** [Quarto](https://quarto.org) or [pandoc](https://pandoc.org), plus a TeX distribution for the PDF.

Settings > Compile shows which tools Chalk found and lets you point it at another folder.

## Build from source

Prerequisites: macOS with Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), Node.js and [pnpm](https://pnpm.io).

```bash
pnpm install
```

**Mac app:** run `scripts/install-mac.sh` to build a Release copy, sign it ad hoc and install it to `~/Applications/Chalk.app`.
Or run `cd mac && xcodegen generate`, open `mac/Chalk.xcodeproj` and run the `Chalk` scheme.
`scripts/release-mac.sh` makes a signed build for other people; see [docs/release-steps.md](docs/release-steps.md).

**VS Code extension:**

```bash
pnpm -C vscode build      # dist/extension.js and dist/webview.js
pnpm -C vscode package    # a .vsix to install with "Install from VSIX..."
```

## How it is built

The engine, [`@chalk/editor-core`](packages/editor-core/), is CodeMirror 6 with KaTeX and a self-contained HyperSnips port.
It knows nothing about its host: the Mac app (native AppKit, editor in a `WKWebView`) and the VS Code extension (a webview) talk to it through the same small `HostPort` protocol.
[CLAUDE.md](CLAUDE.md) describes the architecture in more detail.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

Chalk is released under the [MIT License](LICENSE).
Bundled third-party components keep their own licences, listed in [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES).
