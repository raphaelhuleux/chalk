# Visual test documents

Two long fixtures for eyeballing the live preview. Both tell the *same* story, least squares as orthogonal projection, in the two surface syntaxes Chalk supports, so the rendered boxes can be compared side by side:

- [least-squares.md](least-squares.md) — Quarto fenced-div callouts,
  `$$ … $$ {#eq-x}` equation labels, `@key` cross-references, GFM tables.
- [least-squares.tex](least-squares.tex) — amsthm environments, `\includegraphics`,
  `tabular`, `\ref`/`\cite` (raw by design: cross-reference resolution is
  Markdown-only).

A third fixture covers Beamer:

- [beamer-deck.tex](beamer-deck.tex) — `\begin{frame}` slide cards in both title
  syntaxes, the `block`/`alertblock`/`exampleblock` family, a theorem nested
  inside a frame, and the four scanner traps (a frame quoted inside `verbatim`,
  a commented-out frame, a frame inside a macro definition, and an unclosed
  frame at the end of the file). Its header lists what should render and what
  is deliberately left as raw source.

Each file ends with an **Edge cases** section that is a checklist rather than mathematics. Every case says what *should* happen, so a surprise is a bug and a documented oddity is not. The handful of accepted limitations are labelled **Known limitation** in place.

Figures live in [figures/](figures/) and are generated, not hand-made. One referenced path (`no-such-file.png`) is missing on purpose.

The `.tex` file compiles with `pdflatex` (two passes) **up to**
`\section{Edge cases}`; from there on it deliberately does not, :because unterminated blocks and undefined environments are part of what the preview has to survive.
