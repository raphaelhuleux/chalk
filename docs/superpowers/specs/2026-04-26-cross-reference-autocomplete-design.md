# Cross-Reference Autocomplete — Design

**Date:** 2026-04-26
**Status:** Approved (pending user spec review)
**Scope:** v0.4 of `chalk-math` (tex editor only)

## Goal

Add four new autocomplete contexts to the `.tex` editor:

- `\ref{}` / `\eqref{}` / `\Cref{}` / etc. → labels found across the workspace
- `\cite{}` / `\citep{}` / `\citet{}` / etc. → bib keys from all `.bib` files in the workspace
- `\input{}` / `\include{}` → other `.tex` files in the workspace
- `\includegraphics{}` → image files (`.png`, `.jpg`, `.jpeg`, `.pdf`, `.eps`, `.svg`) in the workspace

Markdown editor is intentionally excluded (per [CLAUDE.md](../../CLAUDE.md) guardrails).

## Non-Goals (v1)

- Live (in-memory, unsaved) label tracking — watcher fires on disk only
- `.bbl` parsing as a fallback bib source
- Cross-workspace `.bib` files
- Hover tooltips on existing `\ref{}`/`\cite{}`
- Diagnostics for broken refs
- Custom sort orders (CM6 default suffices)

## Decisions Made During Brainstorming

| #    | Question                       | Choice                                                                |
| ---- | ------------------------------ | --------------------------------------------------------------------- |
| 1    | Workspace layout assumption    | One workspace = one paper                                             |
| 2    | Popup richness                 | Tier B: key + one-line summary (author, year, or surrounding context) |
| 3    | `.bib` source                  | All `.bib` files in workspace (no `\bibliography{}` parsing)          |
| 4a   | `\input` scope                 | All workspace `.tex`, displayed relative to open doc's directory      |
| 4b   | `\includegraphics` extensions  | `.png .jpg .jpeg .pdf .eps .svg`; respect `\graphicspath{}`           |
| 4c   | Markdown editor                | Skip — tex only                                                       |
| Arch | Scan strategy                  | Eager scan on `ready`, full payload, sync completion source           |

## Architecture

### Module Layout

**New host modules (extension side):**

- [src/extension/refs/scan-tex.ts](../../src/extension/refs/scan-tex.ts) — pure function `parseTex(content): { labels: Label[], inputs: string[], graphicspath: string[] }`
- [src/extension/refs/scan-bib.ts](../../src/extension/refs/scan-bib.ts) — pure function `parseBib(content): BibEntry[]`
- [src/extension/refs/file-finder.ts](../../src/extension/refs/file-finder.ts) — workspace-wide `findFiles(workspace)` returning URIs grouped by category
- [src/extension/refs/refs-service.ts](../../src/extension/refs/refs-service.ts) — `RefsService` class owning the cache, watchers, and post-to-webview callback. One instance per editor panel.

**New webview modules:**

- [src/webview/editor/refs-store.ts](../../src/webview/editor/refs-store.ts) — module-level mutable state holding the latest `RefsPayload`. No CM6 coupling.
- [src/webview/editor/refs-completions.ts](../../src/webview/editor/refs-completions.ts) — CM6 `CompletionSource` branching on trigger context.

**Existing files modified:**

- [src/extension/chalk-editor-provider.ts](../../src/extension/chalk-editor-provider.ts) — instantiate `RefsService` per panel; hook `postRefs` into the `ready` flow alongside `postHsnips`; add `documentUri` and `workspaceUri` to the `init` payload; dispose `RefsService` in `onDidDispose`.
- [src/webview/index.ts](../../src/webview/index.ts) — handle new `refs` message → `setRefs(payload)`. Stash `documentUri`/`workspaceUri` from `init` and pass to refs-store.
- [src/webview/editor/setup.ts](../../src/webview/editor/setup.ts) — register `refsCompletionExtension()` in the tex branch only.

### Message Protocol

Two host→webview message changes:

```ts
// Existing init message gains two fields.
type InitMessage = {
  type: 'init';
  text: string;
  language: 'tex' | 'md';
  documentUri: string;          // NEW: file:// URI of the open document
  workspaceUri: string | null;  // NEW: file:// URI of the workspace folder, or null
};

// New refs message, posted on `ready` and on every watcher event.
type RefsMessage = {
  type: 'refs';
  payload: RefsPayload;
};

type RefsPayload = {
  labels: Array<{
    name: string;          // "eq:euler"
    file: string;          // workspace-relative
    context: string;       // "equation in §3.2 — Euler equation"
  }>;
  bibEntries: Array<{
    key: string;           // "smith2024"
    author: string | null; // first author surname only ("Smith")
    year: string | null;   // "2024"
    title: string | null;  // truncated to ~60 chars
  }>;
  texFiles: string[];      // workspace-relative, .tex extension stripped
  imageFiles: string[];    // workspace-relative, extension kept
};
```

The `refs` message is identical in shape on initial scan and on watcher updates — the host always re-posts the full payload, not deltas. Simpler than diffing; webview just calls `setRefs(payload)`.

### Lifecycle

1. `ChalkEditorProvider.resolveCustomTextEditor` runs.
2. Inside the `ready` handler, after `postThemeColors` / `postHsnips`, instantiate `new RefsService(postRefs)`.
3. `RefsService.initialScan()` runs (fire-and-forget; webview tolerates an empty store).
4. Watchers stay live until `webviewPanel.onDidDispose` fires `RefsService.dispose()`.

The service does not hold a `WorkspaceFolder` reference. `vscode.workspace.findFiles(...)` and `createFileSystemWatcher(...)` already span all open workspace folders, which is the right behavior even when (rarely) the user has multiple folders open. The "no workspace" degenerate case (`workspaceFolders` empty) just makes `findFiles` return nothing — the empty payload propagates and completion silently does nothing.

The `workspaceUri` field in the `init` message is computed as `vscode.workspace.getWorkspaceFolder(document.uri)?.uri.toString() ?? null` — i.e., the folder containing the open document. The webview uses it only for computing display paths (workspace-relative fallback in path resolution), not for scanning.

### Initial Scan Strategy

```text
findFiles('**/*.{tex,bib}', '**/node_modules/**')
  → Promise.all(uris.map(readFile))
  → parse each
  → build single payload
  → postRefs(payload)
```

Image files are listed but not read (we only need their paths).

Expected runtime for a typical paper repo (<50 .tex, 1-3 .bib, ~hundreds of figures): well under 100ms.

### Watcher Behavior

Three `FileSystemWatcher`s:

- `**/*.tex` → on change, re-parse only the changed file, splice into cache, repost full payload
- `**/*.bib` → same
- `**/*.{png,jpg,jpeg,pdf,eps,svg}` → on change, just refresh the file list (no read)

No host-side debouncing. VS Code watchers coalesce. Webview's CM6 completion source is recomputed per keystroke regardless.

### Completion Source

Trigger context regexes ([refs-completions.ts](../../src/webview/editor/refs-completions.ts)):

```ts
const REF_RE   = /\\(?:eq|page|auto|name|c|C)?ref\{[^}]*/;
const CITE_RE  = /\\(?:cite|citep|citet|citealp|citealt|parencite|textcite)\*?\{[^}]*/;
const INPUT_RE = /\\(?:input|include|subfile|import)\{[^}]*/;
const IMG_RE   = /\\includegraphics(?:\[[^\]]*\])?\{[^}]*/;
```

Source matches one via `context.matchBefore(...)`, computes the partial inside the brace, returns options filtered by prefix.

`validFor: /^[^}]*$/` so CM6 re-filters as the user types `/` or `.` without closing the popup.

#### Returned Option Shape

| Trigger              | `label`             | `detail`                        |
| -------------------- | ------------------- | ------------------------------- |
| `\ref{`              | `eq:euler`          | `equation in §3.2`              |
| `\cite{`             | `smith2024`         | `Smith (2024) — Optimal policy` |
| `\input{`            | `sections/intro`    | (empty)                         |
| `\includegraphics{`  | `figs/phillips.pdf` | (empty)                         |

#### Brace-Consume Apply

Same trick as [latex-completions.ts:256-258](../../src/webview/editor/latex-completions.ts#L256-L258): the `apply` function checks the next char and consumes a closing `}` if present, so the user doesn't end up with `\ref{eq:euler}}`.

#### Path Resolution for Display

For `\input{}` and `\includegraphics{}`, the webview computes display strings on the fly:

1. Read `\graphicspath{{a/}{b/}}` from current doc text via regex.
2. For each absolute image path: try expressing as `<graphicspath-entry>/<basename>`; fall back to relative-from-doc-dir; fall back to workspace-relative.
3. For `\input`: relative-from-doc-dir always.

This keeps the host stateless re: open-document content (it only knows about files on disk).

### Coexistence with Existing `latex-completions.ts`

Both completion sources are passed to `autocompletion({ override: [src1, src2] })`. CM6 calls each; first non-null wins for that position. The new contexts only fire after the brace; the existing source matches `\[a-zA-Z]+` before any brace. No overlap.

The existing `\ref` / `\cite` / `\input` *command-name* completions (typing `\re` → suggests `\ref{$1}`) still work; the user types `{`, then the new source kicks in for the argument.

## Edge Cases

| Case                                                | Behavior                                                                                                           |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Open document is itself a `.tex`                    | Included in scan; self-labels available.                                                                           |
| User adds `\label{}` and hasn't saved               | Not visible until save. Acceptable for v1.                                                                         |
| Unsaved files generally                             | Not scanned.                                                                                                       |
| Malformed `.bib` entry                              | Skip the bad entry, parse the rest.                                                                                |
| Duplicate keys across `.bib` files                  | Last write wins, `console.warn` listing the duplicate.                                                             |
| `\input{}` to absolute path outside workspace       | Not in completion list. User can still type manually.                                                              |
| Panel closes during scan                            | `RefsService.dispose()` sets `disposed` flag; in-flight scan checks before `postRefs`.                             |
| Multiple panels open (split editor)                 | Each gets its own `RefsService`. Wasteful, simple, fine for v1.                                                    |
| No workspace folder open (loose `.tex` from Finder) | Skip scan; post empty payload; new completion source returns null and falls through to existing latex-completions. |

## Label Context Extraction

For each `\label{name}` found in a `.tex` file, the parser walks backward in the file to:

1. The nearest enclosing `\begin{env}` (where env ∈ equation, align, gather, figure, table, theorem, lemma, proposition, definition, ...).
2. The nearest preceding `\section{title}` / `\subsection{title}` / `\subsubsection{title}`, counting how many of each have appeared up to this position to derive `§3.2`-style numbering.

Combine into a phrase like `"equation in §3.2"`, `"theorem: Optimal policy"`, `"figure: Phillips curve"`. If neither found, fall back to filename + line number.

Section numbering is approximate (no `\setcounter`, `\appendix`, `\part` handling). Good enough for autocomplete display.

## Bib Parsing

Regex-based, ~80 lines. Handles:

- `@type{key, field=value, ...}` — the common case
- Multi-line entries (across newlines)
- Brace-balanced field values: `title={Foo {Bar} Baz}`
- Quoted values: `title="Foo Bar"`
- `%` comment lines
- Skips `@string{}`, `@preamble{}`, `@comment{}`

Extracts only `key`, `author`, `year`, `title`. Other fields ignored. Author is normalized to first surname only (Smith from `"Smith, John and Doe, Jane"` or `"John Smith and Jane Doe"`).

If a real BibTeX edge case breaks the regex, the entry is skipped silently — the rest of the file still parses.

## Testing

Extend the existing 38-test suite:

- `parseTex` — label extraction, `\input` finding, `\graphicspath` parsing, section-number derivation.
- `parseBib` — normal entries, missing fields, malformed entries, comment lines, `@string{}`, multi-line entries, brace-balanced field values.
- `refs-completions` — completion source returns expected options for each trigger context; brace-consume works; `validFor` keeps popup open through `/`.

No integration tests for `RefsService` itself (would require a vscode test harness; project doesn't have one). Manual smoke test against [test/fixtures/smoke.tex](../../test/fixtures/smoke.tex) plus a hand-built fixture workspace with multiple `.tex` and a `.bib`.

## File Touch Summary

**New (6):**

- `src/extension/refs/scan-tex.ts`
- `src/extension/refs/scan-bib.ts`
- `src/extension/refs/file-finder.ts`
- `src/extension/refs/refs-service.ts`
- `src/webview/editor/refs-store.ts`
- `src/webview/editor/refs-completions.ts`

**Modified (3):**

- `src/extension/chalk-editor-provider.ts`
- `src/webview/index.ts`
- `src/webview/editor/setup.ts`

**Tests (3 new files):**

- `test/scan-tex.test.ts`
- `test/scan-bib.test.ts`
- `test/refs-completions.test.ts`

## Open Risks

- **Bib parser edge cases.** Real-world `.bib` files contain weirdness (LaTeX math in titles, accented chars in author names, jabref-style `@comment{jabref-meta:...}`). The regex parser is lossy by design — if a user reports a bib that doesn't show up, the fix is more regex, not panic. If this becomes recurring, switch to `@retorquere/bibtex-parser` (~30KB).
- **Section numbering accuracy.** The host parses each `.tex` file in isolation, so an `\input{}` chain that crosses files won't get globally consistent numbering. Display-only impact (the actual `\ref{}` resolution at compile time is unaffected). If users complain, switch to per-file local numbering only ("equation 3 in `intro.tex`").
- **Watcher load on huge image trees.** `**/*.{png,jpg,jpeg,pdf,eps,svg}` could match thousands in a graphics-heavy repo. Listing-only (no reads) means cost is bounded by directory enumeration. If this becomes a problem we can defer image scan until first `\includegraphics{` trigger.
