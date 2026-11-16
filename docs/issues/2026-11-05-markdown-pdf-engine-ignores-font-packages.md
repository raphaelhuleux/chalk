# Markdown compiles with the wrong TeX engine when the header loads a pdflatex font package

Status: **open, 2026-11-05.** Not fixed.

## Symptom

A `.md` file whose YAML header loads a pdflatex font package compiles without errors, but the PDF has no bold and the wrong font.
Every glyph is Latin Modern Regular (`pdffonts` lists only `LMRoman12-Regular` and `LMRoman17-Regular`).
Seen on `~/Desktop/01-projects/02-work/2026-job-market/teaching-statement.md`, whose header has:

```yaml
header-includes: |
  \usepackage[sc]{mathpazo}
  \usepackage[scaled]{helvet}
```

## Cause

Both Markdown routes pick a Unicode engine when the header names none:

- quarto (the route taken under `.automatic` when quarto is installed) defaults to `lualatex`;
- pandoc takes `Preferences.pandocPdfEngine`, `xelatex` by default.

`mathpazo` and `helvet` are Type 1 font packages for pdflatex.
Under xelatex or lualatex the log says `LaTeX Font Warning: Font shape 'TU/pplx/m/n' undefined`, and LaTeX falls back to Latin Modern Regular for every shape, bold included.
`pandoc file.md -o file.pdf --pdf-engine=pdflatex` gives the right PDF (URW Palladio Roman, Bold and Italic).

`CompilePlanner.job` (`mac/ChalkKit/Sources/ChalkKit/CompilePlan.swift`) only honours an explicit `pdf-engine:` in the header.
A comment there already notes that "a header built on a pdflatex font package breaks under xelatex", but nothing detects it.

## Fix idea (not done)

Infer the engine from the header when it has no `pdf-engine:`:

- pdflatex when it has `fontfamily:` (pandoc loads it under every engine) or `\usepackage{…}` of a Type 1 font package: `mathpazo`, `palatino`, `pxfonts`, `txfonts`, `mathptmx`, `times`, `helvet`, `courier`, `charter`, `utopia`, `fourier`, `kpfonts`, `newtxtext`, `newtxmath`, `newpxtext`, `newpxmath`, `tgpagella`, `tgtermes`, `tgheros`, `mathdesign`;
- xelatex when it has `mainfont:`, `sansfont:`, `monofont:`, `mathfont:`, `\usepackage{fontspec}`, `\setmainfont` or `\usepackage{unicode-math}` (for example the cover letters in the job-market folder);
- no inference when both kinds appear.

Apply it on both routes: as `--pdf-engine=` for pandoc, and as an override for quarto.
Check first that `quarto render x.md --to pdf -M pdf-engine:pdflatex` switches quarto's engine; this was not tested.
Add a compile note saying why the engine changed, and tests beside the `pdf-engine:` cases in `CompileTests.swift`.

Workaround until then: add `pdf-engine: pdflatex` to the file's header.
