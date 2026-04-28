# Changelog

All notable changes to Chalk are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] — 2026-04-28

### Added

- **Tabout**: `Tab` inside math jumps the cursor past the next closing
  scope — `}`, `]`, `)`, `\right⟨delim⟩`, or the math close itself
  (`$`, `$$`, `\)`, `\]`, `\end{…}`). Repeated presses unwrap nested
  scopes one at a time. `\left…\right` pairs are tracked as a unit so
  an inner balanced pair doesn't consume the outer exit. Inspired by
  Obsidian-Latex-Suite's Tabout; complements (rather than replaces)
  the existing snippet-tabstop convention. Outside math, `Tab` is
  unchanged (snippet advance → autocomplete-accept → indent).

- Vertical `↑` / `↓` arrows now enter a collapsed `$$…$$` block when
  pressed from the line directly above or below it. Down lands at the
  end of the opening `$$`/`\[`/`\begin{…}` line; Up lands at the start
  of the closing line.

### Fixed

- Horizontal `←` / `→` arrows now step into a collapsed `$x^2$` math
  span one position at a time instead of jumping over the entire
  region. Pressing Left from `$x^2$|` lands the caret at `$x^2|$` and
  reveals the source, matching the behaviour every other text editor
  has for hidden ranges.

  Root cause: the math `StateField` was registering its decoration set
  as `EditorView.atomicRanges`, which made CM6 push the cursor over
  the entire `Decoration.replace` span. The atomic registration was
  removed; the existing `cursorInside` reveal logic handles the rest.

## [0.3.2] — 2026-04-26

### Changed

- README now points users at the Marketplace install URL
  (`vscode:extension/RaphalHuleux.chalk-math`) so a single-click install
  works from the rendered listing on github.com. No code changes —
  ships the `a9a0f93` README update as a versioned release.

## [0.3.1] — 2026-04-26

### Changed

- Extension `name` renamed from `chalk` to `chalk-math` because plain
  `chalk` was already registered on the VS Code Marketplace by another
  publisher. `displayName` stays `"Chalk"` so end-users still see
  "Chalk" in search results, install dialogs, and the listing title;
  only the install command and marketplace URL change to
  `RaphalHuleux.chalk-math`.

### Fixed

- Marketplace publisher ID corrected from `raphaelhuleux` to
  `RaphalHuleux` to match the actual publisher namespace registered
  on the VS Code Marketplace (Microsoft auto-derived the ID from the
  account display name with diacritics stripped). This and the name
  rename above were publish-blocking metadata mismatches in 0.3.0;
  functionally identical otherwise. The 0.3.0 .vsix on the GitHub
  Release remains downloadable for sideload installs but never reached
  the marketplace.

## [0.3.0] — 2026-04-26

### Added

- `;$` snippet expanding to a `$$ … $$` display-math block with the
  cursor on the empty middle line. Complements the existing `;;`
  (inline math) and `dm` (`align` environment) triggers.

### Fixed

- Display-math widgets (`$$…$$`, `\[…\]`, `\begin{equation}` and
  friends) no longer surface a horizontal scrollbar — neither the
  per-widget kind nor the editor-wide one on `.cm-scroller`. Root
  cause was KaTeX descendants propagating intrinsic width to CM6's
  `flex-shrink: 0` content area; fixed with `contain: inline-size`
  on the math host plus `overflow-x: clip`.
- Autocomplete and snippet expansion no longer scroll the document
  to the top. Edits are now dispatched as a minimal text diff
  (`webview/utils/text-diff.ts`) instead of a full-document replace,
  so CM6 preserves cursor position and viewport.
- Autocomplete popup inherits VS Code's suggest-widget colors
  (background, selected row, matched-text accent) via
  `--vscode-editorSuggestWidget-*` variables, instead of CM6's
  hard-coded light-mode default.
- Native `::selection` is forced transparent webview-wide so CM6's
  layered selection (semi-transparent, behind text) is the only
  visible selection. Previously, macOS's active ::selection would
  paint opaque white-on-blue on top of math widgets, making selected
  math unreadable while focused.
- Layered selection now uses `opacity: 0.35` so themes that export
  an opaque `editor.selectionBackground` (some Catppuccin variants)
  still let text show through.
- Extension-host edit-loop guard now uses a depth counter and
  `try/finally`, so overlapping edits and `applyEdit` rejection no
  longer strand the panel deaf to subsequent document changes.
- LaTeX cursor-inside-math check is strict-less-than the
  closing-delimiter position; the cursor sitting just past `$` no
  longer reveals raw source, and `math(context)` snippets no longer
  fire one position into text mode.
- HyperSnips `b` (begin-of-line) flag is now enforced — bundled
  `bfig` / `btab` / `beq` / `bal` triggers stop expanding mid-line.
- HyperSnips snippet expansion lands in the same history group as
  the trigger keystroke, so a single Cmd+Z undoes both.
- HyperSnips `$10`, `$11`, … tab stops parse correctly (no longer
  split into `$1` + literal digit).
- HyperSnips session terminates when the cursor wanders out of every
  tab stop's bounding box, preventing stale decorations from
  drifting through unrelated text.
- HyperSnips `passesContextFilter` does an exact equality check for
  `math(context)`; unknown context filters log a one-time warning
  instead of silently dropping the snippet.
- Cross-platform home-dir resolution: switched from `process.env.HOME`
  to `os.homedir()`, so Windows users actually reach
  `%USERPROFILE%/.config/hsnips`.
- Markdown heading-color extraction follows theme `include` chains
  and runs asynchronously, so themes like Catppuccin / Tokyo Night /
  One Dark Pro surface their heading colors and the extension-host
  event loop no longer blocks on theme load.
- Theme/heading colors now refresh on `workbench.colorCustomizations`,
  `editor.tokenColorCustomizations`, and `hsnips.hsnipsPath` changes
  without needing the editor to be reopened.
- External edits to `~/.config/hsnips/*.hsnips` (or whatever
  `hsnips.hsnipsPath` points at) hot-reload the snippet set in any
  open Chalk editor via a `FileSystemWatcher`.
- LaTeX completions resolve the closing-brace consume at apply-time,
  not source-time, so a stale closed-over `to` can no longer delete
  the wrong range when the menu sits open across keystrokes; the
  command-completion list is now pre-filtered by the typed prefix.
- Cross-platform keybinding: `ctrl+shift+;` is the cross-platform
  fallback, with `cmd+shift+;` overriding on macOS — Windows/Linux
  users finally have a way to escape the custom editor by keyboard.
- `extractDisplayLatex` validates the input is wrapped in `$$ … $$`
  before slicing, so any future Lezer parser shape drift can't
  silently shave two real content chars off each end.
- CSP nonce uses `crypto.randomBytes` instead of `Math.random()`.

### Changed

- Build pipeline: `npm run package` invokes the bundler with `--prod`
  so source maps no longer ship in the released `.vsix`.
- `.vscodeignore` fixed so `!dist/**` no longer overrides the
  `**/*.map` exclusion, and references the actual `.eslintrc.cjs`
  filename.
- Marketplace metadata: added `repository`, `bugs`, `homepage`,
  `keywords`, `galleryBanner`, `qna`; broadened `categories`;
  removed `private: true`.

### Known limitations

- **Windows**: untested. The `cmd+shift+;` keybinding has a
  `ctrl+shift+;` cross-platform fallback wired in, but the rest of
  the platform-conditional surface (path separators in user-snippet
  resolution, font fallbacks, native scroll feel) hasn't been
  exercised on a Windows host. Tracked for v0.4 / v1.0 — verify
  before publishing to marketplace.
- **No PDF compilation**. By design — `Ctrl+Shift+;` switches to the
  plain text editor for LaTeX Workshop builds.

## [0.2.0] — 2026-04-26

### Added

- Markdown editor: heading decorations driven by the active theme's
  `markup.heading.N.markdown` rules, inline + display math, bold /
  italic / strikethrough / code / link / blockquote / hr decorations.
- Shared HyperSnips engine across `.tex` and `.md` — math snippets
  fire inside `$ … $` regardless of the host language.
- Bundled default `latex.hsnips` so users without a personal config
  get sensible math snippets out of the box.

### Changed

- Merged the previously-separate `chalk-tex` and `chalk-md` projects
  into a single extension with two custom-editor `viewType`s sharing
  one host shell, KaTeX cache, theme reader, and snippet engine.

### Removed

- Webview-side build path (`chalk.build` command + `Cmd+Alt+B`
  keybinding). LaTeX Workshop's root detection depends on
  `vscode.window.activeTextEditor`, which is undefined when a
  `CustomTextEditorProvider` owns the tab — the bridge couldn't work
  reliably. To compile a `.tex` file, hit `Cmd+Shift+;` to switch to
  the plain text editor and use Workshop from there.
