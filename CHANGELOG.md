# Changelog

All notable changes to Chalk are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Extension-host edit-loop guard now uses a depth counter and `try/finally`,
  so overlapping edits and `applyEdit` rejection no longer strand the panel
  deaf to subsequent document changes.
- LaTeX cursor-inside-math check is strict-less-than the closing-delimiter
  position; the cursor sitting just past `$` no longer reveals raw source,
  and `math(context)` snippets no longer fire one position into text mode.
- HyperSnips `b` (begin-of-line) flag is now enforced — bundled `bfig` /
  `btab` / `beq` / `bal` triggers stop expanding mid-line.
- HyperSnips snippet expansion lands in the same history group as the
  trigger keystroke, so a single Cmd+Z undoes both.
- HyperSnips `$10`, `$11`, … tab stops parse correctly (no longer split
  into `$1` + literal digit).
- HyperSnips session terminates when the cursor wanders out of every tab
  stop's bounding box, preventing stale decorations from drifting through
  unrelated text.
- HyperSnips `passesContextFilter` does an exact equality check for
  `math(context)`; unknown context filters log a one-time warning instead
  of silently dropping the snippet.
- Cross-platform home-dir resolution: switched from `process.env.HOME` to
  `os.homedir()`, so Windows users actually reach `%USERPROFILE%/.config/hsnips`.
- Markdown heading-color extraction follows theme `include` chains and runs
  asynchronously, so themes like Catppuccin / Tokyo Night / One Dark Pro
  surface their heading colors and the extension-host event loop no longer
  blocks on theme load.
- Theme/heading colors now refresh on `workbench.colorCustomizations`,
  `editor.tokenColorCustomizations`, and `hsnips.hsnipsPath` changes
  without needing the editor to be reopened.
- External edits to `~/.config/hsnips/*.hsnips` (or whatever
  `hsnips.hsnipsPath` points at) hot-reload the snippet set in any open
  Chalk editor via a `FileSystemWatcher`.
- LaTeX completions resolve the closing-brace consume at apply-time, not
  source-time, so a stale closed-over `to` can no longer delete the wrong
  range when the menu sits open across keystrokes; the command-completion
  list is now pre-filtered by the typed prefix.
- Cross-platform keybinding: `ctrl+shift+;` is the cross-platform fallback,
  with `cmd+shift+;` overriding on macOS — Windows/Linux users finally have
  a way to escape the custom editor by keyboard.
- `extractDisplayLatex` validates the input is wrapped in `$$ … $$` before
  slicing, so any future Lezer parser shape drift can't silently shave two
  real content chars off each end.
- CSP nonce uses `crypto.randomBytes` instead of `Math.random()`.

### Changed
- Build pipeline: `npm run package` invokes the bundler with `--prod` so
  source maps no longer ship in the released `.vsix`.
- `.vscodeignore` fixed so `!dist/**` no longer overrides the `**/*.map`
  exclusion, and references the actual `.eslintrc.cjs` filename.
- Marketplace metadata: added `repository`, `bugs`, `homepage`, `keywords`,
  `galleryBanner`, `qna`; broadened `categories`; removed `private: true`.

## [0.2.0] — 2026-04-26

### Added
- Markdown editor: heading decorations driven by the active theme's
  `markup.heading.N.markdown` rules, inline + display math, bold / italic /
  strikethrough / code / link / blockquote / hr decorations.
- Shared HyperSnips engine across `.tex` and `.md` — math snippets fire
  inside `$ … $` regardless of the host language.
- Bundled default `latex.hsnips` so users without a personal config get
  sensible math snippets out of the box.

### Changed
- Merged the previously-separate `chalk-tex` and `chalk-md` projects into a
  single extension with two custom-editor `viewType`s sharing one host
  shell, KaTeX cache, theme reader, and snippet engine.

### Removed
- Webview-side build path (`chalk.build` command + `Cmd+Alt+B` keybinding).
  LaTeX Workshop's root detection depends on `vscode.window.activeTextEditor`,
  which is undefined when a `CustomTextEditorProvider` owns the tab — the
  bridge couldn't work reliably. To compile a `.tex` file, hit `Cmd+Shift+;`
  to switch to the plain text editor and use Workshop from there.
