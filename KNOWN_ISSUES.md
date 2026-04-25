# Known issues

## LaTeX Workshop `build` command does not work from inside Chalk-TeX

**Desired behavior:** With a `.tex` file open in the Chalk-TeX custom editor,
running *LaTeX Workshop: Build LaTeX project* from the Command Palette
(`Cmd+Shift+P`) should compile the file exactly as it would in VS Code's
native text editor. Automatic build-on-save is **not** required; manual
invocation is sufficient.

**Current behavior:** Workshop's build command fails to resolve a root
file and either errors ("Cannot find root file") or silently does
nothing.

**Root cause (confirmed):** Workshop's `manager.findRoot()` walks three
paths in order:

1. `findRootFromMagic()` — reads `%!TEX root=…` from
   `vscode.window.activeTextEditor.document`
2. `findRootSelf()` — reads `\documentclass` from the same
3. `findRootInWorkspace()` — fallback scan of the workspace folder

A VS Code `CustomTextEditorProvider` (which Chalk-TeX is) leaves
`activeTextEditor` as `undefined`, so paths 1 and 2 can't run. Path 3
doesn't always trigger cleanly — Workshop short-circuits the chain with
"not a LaTeX document" in some versions.

**What we tried (does not fix it):**

- **User-level:** Adding `% !TEX root = ./file.tex` to the top of the
  source file. Workshop cannot read it — the magic-comment scanner
  dereferences `activeTextEditor.document`.
- **Code-level:** Bridge command in
  [src/extension/workshop-bridge.ts](src/extension/workshop-bridge.ts)
  that, on `Cmd+Alt+B`, opens the doc in a native side-column editor
  with `preserveFocus: true` before calling
  `executeCommand('latex-workshop.build')`. Theory: populating
  `activeTextEditor` with a visible text editor satisfies Workshop's
  root detection. **Result: still fails.** The bridge code is left in
  place as a starting point but currently has no effect.

**Hypotheses for why the bridge doesn't work:**

- `showTextDocument({ preserveFocus: true, viewColumn: Beside })` may
  not actually set `activeTextEditor` when focus stays on the webview —
  `activeTextEditor` might remain `undefined` rather than falling
  through to the last-focused text editor.
- Workshop might cache the "no root" decision once per session and not
  re-run detection on the second `build` invocation.
- Workshop's activation event may fire before the side editor is
  registered, making the first call race against the editor visibility.

**Next things to try (when we pick this up again):**

1. Log `vscode.window.activeTextEditor?.document.uri` from inside the
   bridge command *after* `showTextDocument` resolves, to verify the
   hypothesis that it remains `undefined`.
2. Try `showTextDocument(doc, { preserveFocus: false, ... })` briefly,
   then refocus our webview via `tabGroups` or a saved panel reference —
   ugly but avoids the focus-state question.
3. Use Workshop's exported extension API
   (`vscode.extensions.getExtension('James-Yu.latex-workshop').exports`)
   — inspect what methods it exposes at runtime, specifically whether
   `manager` or `commander` has a `build(uri)` signature we can call
   directly.
4. Set `latex-workshop.latex.rootFile.doNotPrompt` + pin a root via a
   workspace setting that Workshop reads independently of
   `activeTextEditor`.
5. Escalate to the side-panel-preview architecture (see CLAUDE.md
   architecture discussion): native editor for editing + Chalk-TeX as a
   read-mostly preview pane.

**Scope note:** Automatic build-on-save is explicitly **out of scope**
for this issue. Only manual build (palette or keystroke) needs to
work.

## TODO: Windows support

Currently developed and smoke-tested on macOS only. Two known
portability bugs to fix before publishing to the marketplace:

1. **`process.env.HOME` is undefined on Windows**
   ([src/extension/languages/tex.ts:73](src/extension/languages/tex.ts#L73)).
   The hsnips lookup silently fails on Windows because `HOME` doesn't
   exist there — Windows uses `USERPROFILE`. Replace with
   `os.homedir()` from Node's `os` module, which resolves correctly on
   all three platforms.

2. **Keybindings declare `cmd` as the cross-platform default**
   ([package.json:34-47](package.json#L34-L47)). The `key` field is
   the default for all platforms and `mac` overrides it on Mac. Both
   bindings currently set `key` to `cmd+…`, so on Windows/Linux `cmd`
   resolves to the Windows/Super key, which conflicts with the OS.
   Change `key` to `ctrl+alt+b` and `ctrl+shift+;`; keep the existing
   `mac` overrides.

After these fixes, smoke-test the packaged `.vsix` on a Windows VM
before claiming cross-platform support in the marketplace listing —
custom-editor extensions occasionally hit unexpected Chromium webview
differences that aren't predictable from source review.
