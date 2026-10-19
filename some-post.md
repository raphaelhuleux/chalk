# Chalk launch posts

Drafts for each place. Text in [brackets] is for you to fill in: only you can say how you use Chalk, and a personal line is what makes these posts work.

Before posting anywhere:

- Put a signed and notarized `.dmg` in GitHub Releases. Today the README only offers "build from source", and most readers will stop there.
- Check that the links below point to the public repo and that the VS Code extension is on the Marketplace (or remove that line).
- Post in one or two places per week, not all on the same day, so you can answer every comment.

Repo: https://github.com/raphaelhuleux/chalk

---

## Show HN (Hacker News)

**Title** (80 characters max):

Show HN: Chalk – an open-source Markdown and LaTeX editor where math renders as you type

**Text:**

Hi HN, I'm Raphaël, [an economist / a PhD student in economics at …]. I write a lot of math, and I wanted something like Typora, but for LaTeX as well as Markdown, open source, and using my own TeX installation.

Chalk is the result. You edit the real `.tex`, `.md` or `.qmd` file, and equations, theorems, proofs and Beamer frames render in the same pane as you type. Move the cursor back into a formula and you edit its source. There is no separate preview to keep in sync.

On the Mac, Cmd+R compiles with your own latexmk, tectonic, pandoc or Quarto and shows the PDF beside the text, with SyncTeX in both directions. There is also a VS Code extension with the same editor.

Some details that may interest people here:

- The engine is CodeMirror 6 with KaTeX and a port of HyperSnips, so snippets like `dm` or `1/` expand as you type.
- The Mac app is native AppKit with the editor in a WKWebView. Both hosts talk to the engine through one small message protocol.
- Window chrome geometry is checked by a test matrix over every window state rather than by eye.

It is MIT licensed. It has no real-time collaboration, so it does not replace Overleaf for co-writing.

I'd love feedback, especially from people with messy multi-file LaTeX projects: [what you most want to hear about].

---

## r/LaTeX

**Title:** I made a free, open-source LaTeX editor where equations render inline as you type (Mac + VS Code)

**Text:**

I write my papers in LaTeX and always wanted Typora's "what you type is what you see" feel without leaving `.tex` files. So I built Chalk.

- You edit the actual `.tex` file. Math, `equation`/`align` numbering, `\eqref`, theorems, proofs and Beamer frames render in place.
- Cmd+R compiles with your own TeX (latexmk if you have it, otherwise pdflatex/xelatex/lualatex with bibtex or biber, or tectonic). The PDF sits beside the text with SyncTeX both ways.
- Multi-file projects work: saving a chapter compiles the root, found from `% !TEX root`, the `\input` graph or the last build.
- HyperSnips-style snippets, and it reads your existing `.hsnips` files.
- The VS Code extension uses your LaTeX Workshop recipe.

It's MIT licensed: https://github.com/raphaelhuleux/chalk

Known gaps: no collaboration, and [anything else you know is missing]. Bug reports with real documents are very welcome.

[A screenshot of a real paper with the PDF panel open]

---

## r/macapps

**Title:** Chalk: a free, native Markdown and LaTeX editor for writing math

**Text:**

Chalk is a native Mac app (AppKit) for writing math in Markdown or LaTeX. Formulas render where you type them, and the PDF compiles with your own TeX, pandoc or Quarto in a panel beside the text.

- Tabs, a folder sidebar, an outline panel and a split view for two files side by side
- Zen, typewriter and focus modes, four colour themes in light and dark
- Free and open source (MIT)

Download: [link to the release]. Feedback welcome, especially on what feels un-Mac-like.

[A screenshot or the GIF from the README]

---

## r/vscode

**Title:** A VS Code extension that renders LaTeX and Markdown math inline as you type

**Text:**

Chalk opens `.tex`, `.md` and `.qmd` files in an editor where equations, theorems and proofs render in place, so you don't need a side preview. For LaTeX it builds with your LaTeX Workshop recipe, and a click in the PDF jumps back to the source.

Marketplace: [link]. Source (MIT): https://github.com/raphaelhuleux/chalk

One known gap: jumping from the source to the PDF, which LaTeX Workshop only offers from its own text editor.

---

## Product Hunt

**Name:** Chalk

**Tagline** (60 characters max): Write math in Markdown and LaTeX, rendered as you type

**Description:**

Chalk is a free, open-source editor for people who write mathematics. Equations, theorems and proofs render in the same pane as the source, in `.tex`, Markdown or Quarto files. On the Mac it compiles the PDF with your own TeX and shows it beside the text. It also runs as a VS Code extension.

**First comment (from you, the maker):**

Hi everyone. I built Chalk because [your reason]. I write [papers / lecture notes / a thesis] in it every day. It's MIT licensed, and I'd love to hear what's missing for your own writing.

---

## Bluesky / Mastodon (thread)

**1/**
I built a free, open-source editor for writing math: Chalk.
You type LaTeX or Markdown, and equations, theorems and proofs render right where you type them.
Mac app + VS Code extension.
https://github.com/raphaelhuleux/chalk
[GIF]

**2/**
It edits your real `.tex` files, numbers your equations as you go, and compiles with your own TeX. The PDF sits beside the text, and a click in it jumps back to the source.

**3/**
I made it for my own [research / teaching] in [economics]. If you write math for a living and try it, I'd really like to know what breaks.

---

## Demo video: shot list (30 to 60 seconds)

The README has a GIF of typing; a short video with sound off works for every post above.

1. A real `.tex` paper open, with the Library and outline. (3 s)
2. Type an `align` block with snippets (`dm`, `1/`, `sum`); it renders as the cursor leaves. (10 s)
3. `\eqref` a numbered equation; the number appears. (5 s)
4. Cmd+R; the PDF slides in. Cmd-click in the PDF to jump to the source line. (10 s)
5. Switch to a Markdown note with a theorem card and a callout. (5 s)
6. ⌘\ to show the paper and the notes side by side. (5 s)
7. End on the repo URL. (3 s)
