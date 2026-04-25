# Merge chalk-tex and chalk-md into a single `chalk` extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge chalk-tex (this repo) and the archived chalk-md sibling at `~/Desktop/04-archives/2026/chalk/` into one VS Code extension named `chalk` that supports `.tex` and `.md` files via two custom-editor `viewType`s, sharing the host shell, KaTeX cache, theme reader, and hsnips snippet engine.

**Architecture:** One `ChalkEditorProvider` parameterized by a `LanguageProfile` data object (per language: viewType, theme scope candidates, allowed webview commands, hsnips file list, math-context detector). Both `viewType`s register from one `activate()`. Webview is one bundle that branches in `setup.ts` on a `language` field carried in the `init` message. Hsnips engine becomes language-agnostic by accepting an injected `isInMathContext` callback — tex passes its `scanMathRegions`-based detector, md passes a lezer-tree query.

**Tech Stack:** TypeScript 5, VS Code Extension API ≥1.90, CodeMirror 6 (`@codemirror/*`), `@codemirror/lang-markdown` + `@lezer/markdown` (added in Phase 6), `@codemirror/legacy-modes` (stex), KaTeX 0.16, esbuild, vitest with jsdom.

**Working directory:** `/Users/raphaelhuleux/Desktop/01-projects/03-personal/chalk-tex` — merge in place. Source-of-truth for chalk-md is the archived copy at `/Users/raphaelhuleux/Desktop/04-archives/2026/chalk/`. Files copied across keep their content and lose their git history (chalk-md is archived; the merged extension's history starts fresh from chalk-tex's branch).

**Estimated effort:** ~5 hours focused work, ~63 tasks across 10 phases. Each phase ends with a `git commit`. The tex extension keeps working at every commit point until Phase 8, after which both languages must work.

**Definition of done:** `code --install-extension chalk-0.2.0.vsix` followed by opening (a) `test/fixtures/smoke.tex` renders math; (b) `test/fixtures/smoke.md` renders math + headings; (c) hsnips expands `fr → \frac{$1}{$2}$0` inside `$…$` regions in both file types; (d) `vitest run` passes; (e) `npm run package` produces `chalk-0.2.0.vsix` with no errors.

---

## Phase 0: Pre-merge cleanup of chalk-tex

Before merging, remove debug noise and dead code so we don't carry it into the merged codebase. The tex extension must keep working unchanged after this phase. The build is **currently broken** at the TypeScript level (two pre-existing errors); Task 0.0 fixes both.

### Task 0.0: Fix pre-existing TypeScript errors

**Files:**
- Modify: `src/webview/editor/latex-completions.ts:263`
- Modify: `src/webview/editor/setup.ts:99-114` (the entire `buildAllExtensions` block)

Two errors block `npx tsc --noEmit`:
1. `latex-completions.ts:263` — `Cannot find name 'suffix'`. The `\end{` completion branch references an undeclared `suffix` variable. The intent: in `\end{` mode, just insert the env name; close the brace if not already there.
2. `setup.ts:113` — `Type 'Extension' must have a '[Symbol.iterator]()' method`. `hsnipsExtension()` returns a typed `Extension` (a union including non-iterable shapes), so `...hsnips` fails type-check. Fix: drop the spread — CM6 accepts nested arrays of extensions and recursively flattens them. While there, also delete the debug `testListener`.

- [ ] **Step 1: Fix `latex-completions.ts:263`**

In the `\end{` branch (lines 262-264), replace:
```ts
          if (!isBegin) {
            return { label: e, type: 'keyword', apply: e + suffix };
          }
```
with:
```ts
          if (!isBegin) {
            return { label: e, type: 'keyword', apply: hasClosingBrace ? e : e + '}' };
          }
```

`hasClosingBrace` is already declared at line 251 in the same function scope.

- [ ] **Step 2: Fix `setup.ts:113` and delete the debug testListener**

Replace the entire `buildAllExtensions` function (lines 99-114) with:
```ts
/**
 * Wraps buildExtensions and appends HyperSnips support.
 */
export function buildAllExtensions(actions: EditorActions) {
  const base = buildExtensions(actions);
  return [...base, hsnipsExtension()];
}
```

(No spread on `hsnipsExtension()`. Tests in Phase 0.5 collapse this further.)

- [ ] **Step 3: Verify both fixes compile**

Run: `npx tsc --noEmit`
Expected: clean output, no errors.

- [ ] **Step 4: Verify build still produces bundles**

Run: `npm run build`
Expected: clean. `dist/extension.js` and `dist/webview.js` exist.

### Task 0.1: Remove debug `console.log` statements from the hsnips path

**Files:**
- Modify: `src/webview/editor/hsnips-plugin.ts:359` and `:375`
- Modify: `src/extension/chalk-tex-editor-provider.ts:86`, `:92`, `:94`
- Modify: `src/webview/index.ts:108`, `:111`, `:115`
- Modify: `src/webview/editor/setup.ts:93-95`

- [ ] **Step 1: Remove logs in `hsnips-plugin.ts`**

In `autoExpand` (around line 359), change:

```ts
update.transactions.forEach((tr) => {
    tr.changes.iterChanges((_fromA, _toA, _fromB, _toB, inserted) => {
      const str = inserted.sliceString(0);
      console.log('[hsnips] change inserted:', JSON.stringify(str), 'length:', str.length);
      if (str.length >= 1) {
        isKeystroke = true;
      }
    });
  });
```

to:

```ts
update.transactions.forEach((tr) => {
    tr.changes.iterChanges((_fromA, _toA, _fromB, _toB, inserted) => {
      if (inserted.length >= 1) isKeystroke = true;
    });
  });
```

Also delete the line near 375:

```ts
    console.log('[hsnips] Match found:', match.snippet.trigger || match.snippet.regexp?.source, '→', match.snippet.body.slice(0, 40));
```

- [ ] **Step 2: Remove logs in `chalk-tex-editor-provider.ts`**

Replace the `'ready'` case body block (lines 86, 92, 94) with the version stripped of `console.log`:

```ts
        case 'ready': {
          webviewReady = true;
          webviewPanel.webview.postMessage({
            type: 'init',
            text: document.getText(),
          });
          void postThemeColors();

          const hsnipsRaw = loadHSnipsRaw();
          if (hsnipsRaw) {
            webviewPanel.webview.postMessage({
              type: 'hsnips',
              content: hsnipsRaw,
            });
          }

          if (pendingUpdate !== null) {
            webviewPanel.webview.postMessage({
              type: 'update',
              text: pendingUpdate,
            });
            pendingUpdate = null;
          }
          return;
        }
```

- [ ] **Step 3: Remove logs in `webview/index.ts`**

In the `'hsnips'` case (lines 107-117), replace with:

```ts
    case 'hsnips': {
      if (!view) return;
      const snippets = parseHSnips(msg.content);
      view.dispatch({
        effects: [setSnippets.of(snippets)],
      });
      return;
    }
```

- [ ] **Step 4: Remove logs in `setup.ts`**

In `buildAllExtensions` (lines 91-97), keep the function but drop the logging:

```ts
export function buildAllExtensions(actions: EditorActions) {
  const base = buildExtensions(actions);
  const hsnips = hsnipsExtension();
  return [...base, ...hsnips];
}
```

- [ ] **Step 5: Verify no `console.log` calls remain in the hsnips path**

Run: `grep -n "console.log" src/extension/chalk-tex-editor-provider.ts src/webview/index.ts src/webview/editor/hsnips-*.ts src/webview/editor/setup.ts`

Expected: empty output.

### Task 0.2: Remove dead processBody loop

**Files:**
- Modify: `src/webview/editor/hsnips-plugin.ts:218-231`

- [ ] **Step 1: Remove the no-op loop**

Delete lines 218-231 (the `if (groups.length > 0)` block with the empty for-loop containing only a comment) and the now-unused `processed` variable initialization. Replace the head of `processBody` with:

```ts
function processBody(
  body: string,
  insertPos: number,
  groups: string[],
): ProcessedSnippet {
  void groups; // regex group substitution intentionally not supported (JS blocks discarded)

  const tabStops: TabStop[] = [];
  let text = '';
  let offset = insertPos;
  let i = 0;

  while (i < body.length) {
```

Then update all subsequent `processed` references in the function body (lines ~239-298) to `body`. Specifically:
- Line 240: `if (processed[i] === '$' && i + 1 < processed.length)` → `if (body[i] === '$' && i + 1 < body.length)`
- Line 242: `if (processed[i + 1] === '{')` → `if (body[i + 1] === '{')`
- Line 244: `processed.indexOf('}', i + 2)` → `body.indexOf('}', i + 2)`
- Line 246: `processed.slice(i + 2, closeIdx)` → `body.slice(i + 2, closeIdx)`
- Line 271: `if (/[0-9]/.test(processed[i + 1]))` → `if (/[0-9]/.test(body[i + 1]))`
- Line 272: `parseInt(processed[i + 1], 10)` → `parseInt(body[i + 1], 10)`
- Line 278: `text += processed[i]` → `text += body[i]`
- Line 281: `if (processed[i] === '\\' && i + 1 < processed.length)` → `if (body[i] === '\\' && i + 1 < body.length)`
- Line 284: `const next = processed[i + 1]` → `const next = body[i + 1]`
- Line 290: `text += processed[i] + next` → `text += body[i] + next`
- Line 295: `text += processed[i]` → `text += body[i]`

### Task 0.3: Remove unused `hsnippetsFacet`

**Files:**
- Modify: `src/webview/editor/hsnips-plugin.ts:34-39`

- [ ] **Step 1: Delete the unused facet**

Delete lines 34-39 (the `hsnippetsFacet` definition and its leading comment header). Also remove `Facet` from the imports at the top of the file (line 30). The `setSnippets` effect and `snippetsField` are the actual snippet-update path and stay.

After change, line 30 should read:
```ts
} from '@codemirror/state';
```
without `Facet`.

### Task 0.4: Simplify `chalkKeymap` signature — drop unused parameter

**Files:**
- Modify: `src/webview/editor/keymap.ts:21`
- Modify: `src/webview/editor/setup.ts:49`

- [ ] **Step 1: Simplify keymap.ts**

Replace the function definition (lines 21-31):

```ts
export function chalkKeymap(): KeyBinding[] {
  return [
    {
      key: 'Mod-Alt-b',
      run: () => {
        sendCommand('chalk-tex.build');
        return true;
      },
    },
  ];
}
```

The `EditorActions` interface (lines 10-12) stays — it's still used by `buildExtensions`'s update listener and `createEditor`.

- [ ] **Step 2: Update setup.ts call site**

Line 49: change `keymap.of(chalkKeymap(actions))` to `keymap.of(chalkKeymap())`.

### Task 0.5: Collapse `buildExtensions` and `buildAllExtensions` into one function

**Files:**
- Modify: `src/webview/editor/setup.ts:47-97`

- [ ] **Step 1: Delete `buildAllExtensions` and inline the hsnips append**

Replace the entire body of `setup.ts` (after the imports section) with a single `buildExtensions` that always includes hsnips and the LaTeX autocomplete extension. Note the `hsnipsKeymap` precedes `indentWithTab` — Tab must reach hsnips' tab-stop nav before falling through to indent. And `hsnipsExtension()` is a single nested-array extension (CM6 flattens it), no spread needed.

```ts
/**
 * Builds the full extensions array for a CM6 editor instance.
 *
 * vs. chalk-md:
 *   - `stex` stream language replaces `markdown(…)` for syntax highlighting
 *   - `texMathPlugin()` replaces `mathPlugin()` + `livePreviewPlugin()`
 *     (there is no live-preview for prose; only math widgets)
 *   - no `previewCompartment` wrapper (math is always on; use VS Code's
 *     "Reopen With → Text Editor" if you want raw LaTeX)
 *   - `latexCompletionExtension()` provides \begin{...} and \command
 *     autocomplete. Tex-only — markdown will not get this in Phase 7.
 */
export function buildExtensions(actions: EditorActions) {
  return [
    keymap.of(hsnipsKeymap),
    keymap.of([{ key: 'Tab', run: acceptCompletion }]),
    keymap.of(chalkKeymap()),

    keymap.of([indentWithTab]),
    keymap.of(closeBracketsKeymap),
    keymap.of(historyKeymap),
    keymap.of(searchKeymap),
    keymap.of(defaultKeymap),

    lineNumbers(),
    history(),
    bracketMatching(),
    closeBrackets(),
    drawSelection(),
    highlightSpecialChars(),
    highlightSelectionMatches(),

    indentUnit.of('    '),

    StreamLanguage.define(stex),
    syntaxHighlighting(texHighlightStyle),

    texMathPlugin(),
    hsnipsExtension(),
    latexCompletionExtension(),

    EditorView.lineWrapping,

    placeholder('% Start typing LaTeX…'),

    EditorView.updateListener.of((update) => {
      if (update.docChanged) {
        actions.onContentChange(update.state.doc.toString());
      }
    }),

    themeCompartment.of(vsCodeTheme()),
  ];
}
```

Imports must include (already present in setup.ts as of Task 0.0; just confirm):
```ts
import { acceptCompletion, closeBrackets, closeBracketsKeymap } from '@codemirror/autocomplete';
import { hsnipsExtension, hsnipsKeymap } from './hsnips-plugin';
import { latexCompletionExtension } from './latex-completions';
```

- [ ] **Step 2: Update `createEditorState` to call new function**

Lines 99-107 already call `buildAllExtensions`. Change to `buildExtensions`:

```ts
export function createEditorState(
  content: string,
  actions: EditorActions,
): EditorState {
  return EditorState.create({
    doc: content,
    extensions: buildExtensions(actions),
  });
}
```

### Task 0.6: Remove unused `@codemirror/lint` dep

**Files:**
- Modify: `package.json:75`

- [ ] **Step 1: Confirm lint isn't imported anywhere**

Run: `grep -r "@codemirror/lint" src/`

Expected: empty output.

- [ ] **Step 2: Remove the dep**

Edit `package.json` to delete the line:
```json
    "@codemirror/lint": "^6.9.4",
```

- [ ] **Step 3: Run `npm install`**

Run: `npm install`
Expected: completes without errors.

### Task 0.7: Run tests + build to verify Phase 0 cleanup

- [ ] **Step 1: Run unit tests**

Run: `npm test`
Expected: theme-reader tests pass.

- [ ] **Step 2: Build**

Run: `npm run build`
Expected: completes without errors. `dist/extension.js` and `dist/webview.js` exist.

- [ ] **Step 3: Manual smoke test (optional but recommended)**

```bash
npm run package
code --install-extension chalk-tex-0.1.0.vsix --force
```

Open `test/fixtures/smoke.tex` in VS Code. Verify:
- inline math renders (`$a^2 + b^2 = c^2$`)
- display math renders (`$$…$$`, `\[…\]`, `\begin{equation}…\end{equation}`)
- hsnips trigger `fr` inside math expands to `\frac{}{}` (assumes a `~/.config/hsnips/latex.hsnips` with that snippet exists)

### Task 0.8: Commit Phase 0

- [ ] **Step 1: Stage and commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
chore: pre-merge cleanup of debug logs and dead code

Removes console.log debug statements from the hsnips path, the no-op
processBody loop, the unused hsnippetsFacet, and the unused EditorActions
parameter in chalkKeymap. Collapses buildExtensions/buildAllExtensions.
Drops unused @codemirror/lint dep.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 1: Rename package chalk-tex → chalk

Rename the package, viewType, command IDs, and CSS variable prefix from `chalk-tex` to `chalk`. The extension still only handles `.tex` files; markdown support arrives in later phases. After this phase the rename is complete and all subsequent code uses `chalk.*`.

### Task 1.1: Update package.json

**Files:**
- Modify: `package.json`

- [ ] **Step 1: Rewrite the metadata fields and contributes section**

Replace the top of `package.json` (lines 2-8) with:

```json
  "name": "chalk",
  "displayName": "Chalk",
  "description": "Live-preview editor for LaTeX (.tex) and Markdown (.md) files with first-class math support, running inside VS Code.",
  "version": "0.1.0",
  "publisher": "raphaelhuleux",
  "license": "MIT",
  "private": true,
```

Replace the `contributes` block (lines 13-48) with:

```json
  "contributes": {
    "customEditors": [
      {
        "viewType": "chalk.texEditor",
        "displayName": "Chalk",
        "selector": [{ "filenamePattern": "*.tex" }],
        "priority": "default"
      }
    ],
    "commands": [
      {
        "command": "chalk.build",
        "title": "Build (LaTeX Workshop)",
        "category": "Chalk"
      },
      {
        "command": "chalk.diagnoseTheme",
        "title": "Diagnose Theme Resolution",
        "category": "Chalk"
      }
    ],
    "keybindings": [
      {
        "command": "workbench.action.reopenWithEditor",
        "key": "cmd+shift+;",
        "mac": "cmd+shift+;",
        "when": "resourceExtname == .tex"
      },
      {
        "command": "chalk.build",
        "key": "cmd+alt+b",
        "mac": "cmd+alt+b",
        "when": "activeCustomEditorId == 'chalk.texEditor'"
      }
    ]
  },
```

Note: the markdown viewType + keybinding are added in Phase 8, not now. This keeps Phase 1 a pure rename.

### Task 1.2: Update source code references

**Files:**
- Modify: `src/extension/index.ts`
- Modify: `src/extension/workshop-bridge.ts:58`
- Modify: `src/extension/chalk-tex-editor-provider.ts:7,29`
- Modify: `src/webview/editor/keymap.ts:26`
- Modify: `src/extension/webview-html.ts:58`

- [ ] **Step 1: `index.ts` — output channel name**

Line 7 says `vscode.window.createOutputChannel('Chalk-TeX')`. Change to `'Chalk'`.

Lines 21-22 register `chalk-tex.build` and `chalk-tex.diagnoseTheme`. Change to `chalk.build` and `chalk.diagnoseTheme`.

Replace the `activate` body (lines 6-29) with:

```ts
export function activate(context: vscode.ExtensionContext): void {
  const diagChannel = vscode.window.createOutputChannel('Chalk');

  context.subscriptions.push(
    vscode.window.registerCustomEditorProvider(
      ChalkTexEditorProvider.viewType,
      new ChalkTexEditorProvider(context),
      {
        webviewOptions: {
          retainContextWhenHidden: true,
        },
        supportsMultipleEditorsPerDocument: false,
      },
    ),
    vscode.commands.registerCommand('chalk.build', buildWithWorkshop),
    vscode.commands.registerCommand('chalk.diagnoseTheme', async () => {
      const diag = await diagnoseThemeResolution();
      diagChannel.clear();
      diagChannel.appendLine(JSON.stringify(diag, null, 2));
      diagChannel.show(true);
    }),
    diagChannel,
  );
}
```

- [ ] **Step 2: `workshop-bridge.ts` — viewType check**

Line 58: change `tab.input.viewType === 'chalk-tex.texEditor'` to `tab.input.viewType === 'chalk.texEditor'`.

Update the error message at line 21-23 from `'Chalk-TeX: LaTeX Workshop is not installed…'` to `'Chalk: LaTeX Workshop is not installed…'`. Same at line 32-34: `'Chalk-TeX: no active .tex document to build.'` → `'Chalk: no active .tex document to build.'`.

- [ ] **Step 3: `chalk-tex-editor-provider.ts` — viewType + allowed commands**

Line 7: change `WEBVIEW_ALLOWED_COMMANDS = new Set(['chalk-tex.build'])` to `WEBVIEW_ALLOWED_COMMANDS = new Set(['chalk.build'])`.

Line 29: change `public static readonly viewType = 'chalk-tex.texEditor'` to `public static readonly viewType = 'chalk.texEditor'`.

(The class name still ends in `Tex` — Phase 2 renames it to `ChalkEditorProvider`.)

- [ ] **Step 4: `keymap.ts` — sendCommand id**

Line 26: change `sendCommand('chalk-tex.build')` to `sendCommand('chalk.build')`.

- [ ] **Step 5: `webview-html.ts` — title tag**

Line 58: change `<title>Chalk-TeX</title>` to `<title>Chalk</title>`.

### Task 1.3: Rename CSS variable prefix `--chalk-tex-syntax-*` → `--chalk-syntax-*`

**Files:**
- Modify: `src/webview/editor/syntax-highlight.ts`
- Modify: `src/webview/index.ts:64-71`
- Modify: any other reference

- [ ] **Step 1: Find all references**

Run: `grep -rn "chalk-tex-syntax" src/`

Expected: matches in `syntax-highlight.ts` (CSS var fallbacks) and `webview/index.ts` (CSS var setters).

- [ ] **Step 2: Update `syntax-highlight.ts`**

Replace all `--chalk-tex-syntax-…` with `--chalk-syntax-…`. Specifically lines 20, 23, 28, 32, 34, 39, 45, 51 in [src/webview/editor/syntax-highlight.ts](src/webview/editor/syntax-highlight.ts). For example:

```ts
{ tag: t.keyword, color: 'var(--chalk-syntax-keyword, #569cd6)' },
```

(One sed-style pass: every `--chalk-tex-syntax-` substring drops `-tex`.)

- [ ] **Step 3: Update `webview/index.ts`**

Replace lines 64-71:

```ts
  set('--chalk-syntax-keyword', colors.keyword);
  set('--chalk-syntax-tag', colors.tagName);
  set('--chalk-syntax-comment', colors.comment);
  set('--chalk-syntax-number', colors.number);
  set('--chalk-syntax-atom', colors.atom);
  set('--chalk-syntax-bracket', colors.bracket);
  set('--chalk-syntax-special-variable', colors.specialVariable);
  set('--chalk-syntax-invalid', colors.invalid);
```

- [ ] **Step 4: Verify**

Run: `grep -rn "chalk-tex-syntax" src/`

Expected: empty output.

### Task 1.4: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Replace the heading and intro**

Current line 1 is `# Chalk-TeX`. Change to `# Chalk`.

Current lines 3-5 are:
```
Live math preview for `.tex` files, packaged as a VS Code custom editor
extension. Sibling to [Chalk](../chalk/) (markdown editor); shares the same
architecture minus the markdown-specific bits.
```

Change to:
```
Live-preview editor for `.tex` and `.md` files with first-class math
support, packaged as a VS Code custom editor extension. Two `viewType`s
(`chalk.texEditor`, `chalk.markdownEditor`) share one host shell, KaTeX
cache, theme reader, and hsnips snippet engine; per-language CodeMirror
extensions diverge in `setup.ts`.
```

(The detailed table at lines 19-31 stays, since it's still accurate as a description of what makes the tex editor specifically different. Phase 10 revisits it.)

- [ ] **Step 2: Replace remaining `chalk-tex` references in CLAUDE.md**

Run: `grep -n "chalk-tex" CLAUDE.md`

For each match:
- viewType strings (`chalk-tex.texEditor`) → `chalk.texEditor`
- command IDs (`chalk-tex.build`) → `chalk.build`
- CSS var refs (`--chalk-tex-syntax-`) → `--chalk-syntax-`
- prose mentions of the package name → `chalk` (e.g., "Chalk-TeX is math-only by design" → "the tex editor is math-only by design")

### Task 1.5: Build, smoke test, commit Phase 1

- [ ] **Step 1: Build**

Run: `npm run build`
Expected: clean.

- [ ] **Step 2: Final grep check**

Run: `grep -rn "chalk-tex" src/ package.json CLAUDE.md`

Expected: empty (the only remaining mentions of "chalk-tex" should be in `KNOWN_ISSUES.md` referencing the historical chalk-tex name; that's fine for this phase). If anything in src/ matches, fix it.

- [ ] **Step 3: Run unit tests**

Run: `npm test`
Expected: pass.

- [ ] **Step 4: Stage and commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: rename chalk-tex package to chalk

Renames the extension from chalk-tex to chalk in preparation for adding
markdown support. ViewType chalk-tex.texEditor becomes chalk.texEditor,
commands chalk-tex.build/diagnoseTheme become chalk.build/diagnoseTheme,
CSS vars --chalk-tex-syntax-* become --chalk-syntax-*. No behavioral
change yet — extension still handles only .tex.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2: Introduce LanguageProfile abstraction

Create a `LanguageProfile` data structure that encapsulates everything language-specific the host needs (viewType, allowed commands, hsnips loader, theme scope candidates). Pass it to the provider constructor. After this phase the tex provider is parameterized but still only registered for tex.

### Task 2.1: Create `src/extension/languages/types.ts`

**Files:**
- Create: `src/extension/languages/types.ts`

- [ ] **Step 1: Write the LanguageProfile interface**

```ts
import type * as vscode from 'vscode';

/**
 * Per-language data passed into ChalkEditorProvider. Captures everything
 * the host shell needs to know that depends on the file type — viewType
 * registration, allowed webview commands, hsnips loading, theme scopes.
 *
 * The webview-side language switch (markdown vs stex CM extensions, math
 * detection strategy, live-preview decorations) is driven separately by
 * the `language` field carried in the `init` message — see
 * src/webview/editor/setup.ts.
 */
export interface LanguageProfile {
  /** Unique webview-side identifier. Sent in the `init` message; setup.ts
   *  branches on it to choose CM6 extensions. */
  id: 'tex' | 'md';

  /** Custom-editor viewType registered in package.json's customEditors. */
  viewType: string;

  /** Commands the webview is allowed to invoke via the `command` message.
   *  Keeps the message bridge from becoming an arbitrary-command executor. */
  allowedWebviewCommands: Set<string>;

  /** TextMate scope candidates per CM6 highlight tag, used by theme-reader
   *  to look up colors in the active theme's tokenColors. Empty for languages
   *  that don't drive a syntax HighlightStyle (md uses lezer-markdown's
   *  built-in highlighting + a separate heading-color path). */
  themeScopeCandidates: Record<string, string[]>;

  /** Read all hsnips files relevant to this language and return their raw
   *  text concatenated. Returns null if none exist. Called once per editor
   *  open, on the `ready` message. */
  loadHsnips: () => string | null;
}
```

### Task 2.2: Create `src/extension/languages/tex.ts` with the tex profile

**Files:**
- Create: `src/extension/languages/tex.ts`

- [ ] **Step 1: Write the tex profile (copying SCOPE_CANDIDATES verbatim from theme-reader.ts)**

Note: `loadHsnips` reuses the same logic that lives in `chalk-tex-editor-provider.ts` lines 9-26 today — Phase 2.4 deletes it from there.

```ts
import { existsSync, readFileSync } from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';
import type { LanguageProfile } from './types';

/**
 * TextMate scope candidates for the LaTeX (stex) tokens. Most-specific
 * scope first; the theme-reader walks each list and stops at the first
 * match. Tuned against scopes that LaTeX grammars (Workshop's, VS Code's
 * built-in) emit.
 */
const TEX_SCOPE_CANDIDATES: Record<string, string[]> = {
  keyword: [
    'support.function.be.latex',
    'keyword.control.preamble.latex',
    'support.function.general.latex',
    'keyword.control.latex',
    'support.function.latex',
    'entity.name.function.latex',
    'keyword.control',
    'support.function',
    'entity.name.function',
    'keyword',
  ],
  tagName: [
    'entity.name.function.environment.latex',
    'support.class.latex',
    'entity.name.type.environment.latex',
    'entity.name.function.latex',
    'entity.name.type.latex',
    'entity.name.type',
    'support.class',
    'entity.name.tag',
    'entity.name',
    'variable.parameter',
  ],
  comment: [
    'comment.line.percentage.latex',
    'comment.line.percentage',
    'comment.line',
    'comment',
  ],
  number: ['constant.numeric.latex', 'constant.numeric', 'constant'],
  atom: [
    'constant.character.latex',
    'constant.character',
    'constant.language',
    'constant.other',
    'constant',
  ],
  bracket: [
    'punctuation.definition.arguments.begin.latex',
    'punctuation.definition.arguments',
    'punctuation.definition',
    'punctuation.section',
    'punctuation',
  ],
  specialVariable: [
    'variable.parameter.function.latex',
    'variable.parameter.latex',
    'variable.parameter',
    'variable.other',
    'variable',
  ],
  invalid: ['invalid.illegal', 'invalid.deprecated', 'invalid'],
};

/**
 * Loads `latex.hsnips` from the user's HyperSnips directory. Checks the
 * `hsnips.hsnipsPath` setting first (compatible with the real HyperSnips
 * extension), then falls back to ~/.config/hsnips.
 */
function loadLatexHsnips(): string | null {
  const config = vscode.workspace.getConfiguration('hsnips');
  const customPath = config.get<string>('hsnipsPath');
  const searchDirs = [
    customPath,
    path.join(process.env.HOME || '', '.config', 'hsnips'),
  ].filter(Boolean) as string[];

  for (const dir of searchDirs) {
    const filePath = path.join(dir, 'latex.hsnips');
    if (existsSync(filePath)) {
      return readFileSync(filePath, 'utf8');
    }
  }
  return null;
}

export const texProfile: LanguageProfile = {
  id: 'tex',
  viewType: 'chalk.texEditor',
  allowedWebviewCommands: new Set(['chalk.build']),
  themeScopeCandidates: TEX_SCOPE_CANDIDATES,
  loadHsnips: loadLatexHsnips,
};
```

### Task 2.3: Refactor provider class to take a `LanguageProfile`

**Files:**
- Modify: `src/extension/chalk-tex-editor-provider.ts`

- [ ] **Step 1: Rename the class to `ChalkEditorProvider`**

In the file (line 28), the class declaration becomes:

```ts
export class ChalkEditorProvider implements vscode.CustomTextEditorProvider {
  constructor(
    private readonly context: vscode.ExtensionContext,
    private readonly profile: LanguageProfile,
  ) {}
```

Add the import at the top:
```ts
import type { LanguageProfile } from './languages/types';
```

Delete the `public static readonly viewType = 'chalk.texEditor'` line — viewType now comes from `profile.viewType`, and the registration site reads it directly from the profile.

- [ ] **Step 2: Replace the inline `loadHSnipsRaw` with `profile.loadHsnips`**

Delete lines 9-26 of the original file (the local `loadHSnipsRaw` function — moved to `tex.ts` as `loadLatexHsnips`).

In the `'ready'` case body, replace:
```ts
const hsnipsRaw = loadHSnipsRaw();
```
with:
```ts
const hsnipsRaw = this.profile.loadHsnips();
```

- [ ] **Step 3: Replace `WEBVIEW_ALLOWED_COMMANDS` with `profile.allowedWebviewCommands`**

Delete the file-level `const WEBVIEW_ALLOWED_COMMANDS = new Set(['chalk.build']);` line at the top.

In the `'command'` case (line ~131), change:
```ts
if (!WEBVIEW_ALLOWED_COMMANDS.has(msg.id)) return;
```
to:
```ts
if (!this.profile.allowedWebviewCommands.has(msg.id)) return;
```

### Task 2.4: Rename the provider file

**Files:**
- Rename: `src/extension/chalk-tex-editor-provider.ts` → `src/extension/chalk-editor-provider.ts`

- [ ] **Step 1: Move the file**

```bash
git mv src/extension/chalk-tex-editor-provider.ts src/extension/chalk-editor-provider.ts
```

- [ ] **Step 2: Update the import in `extension/index.ts`**

Change line 2 from:
```ts
import { ChalkTexEditorProvider } from './chalk-tex-editor-provider';
```
to:
```ts
import { ChalkEditorProvider } from './chalk-editor-provider';
import { texProfile } from './languages/tex';
```

Update the registration call inside `activate()`:
```ts
    vscode.window.registerCustomEditorProvider(
      texProfile.viewType,
      new ChalkEditorProvider(context, texProfile),
      {
        webviewOptions: {
          retainContextWhenHidden: true,
        },
        supportsMultipleEditorsPerDocument: false,
      },
    ),
```

### Task 2.5: Pass `language` field through the `init` message

**Files:**
- Modify: `src/extension/chalk-editor-provider.ts` — `'ready'` case
- Modify: `src/webview/index.ts` — `ExtensionMessage` union and `init` handler

- [ ] **Step 1: Provider — add `language` to init payload**

In the `'ready'` case body, change:
```ts
webviewPanel.webview.postMessage({
  type: 'init',
  text: document.getText(),
});
```
to:
```ts
webviewPanel.webview.postMessage({
  type: 'init',
  text: document.getText(),
  language: this.profile.id,
});
```

- [ ] **Step 2: Webview — accept and use the `language` field**

In `src/webview/index.ts`, update the `ExtensionMessage` union (line 46-50). Add `language` to the init variant:

```ts
type Language = 'tex' | 'md';

type ExtensionMessage =
  | { type: 'init'; text: string; language: Language }
  | { type: 'update'; text: string }
  | { type: 'theme-colors'; colors: ThemeColors }
  | { type: 'hsnips'; content: string };
```

In the `'init'` case (lines 76-89), pass the language through to `createEditor`:

```ts
case 'init': {
  lastKnownText = msg.text;
  const root = document.getElementById('editor-root');
  if (!root) {
    console.error('#editor-root not found');
    return;
  }
  if (view) {
    view.destroy();
    view = null;
  }
  view = createEditor(root, msg.text, actions, msg.language);
  return;
}
```

- [ ] **Step 3: Update `createEditor` and `createEditorState` signatures**

In `src/webview/editor/setup.ts`, lines 99-118. Change to:

```ts
export function createEditorState(
  content: string,
  actions: EditorActions,
  _language: 'tex' | 'md',
): EditorState {
  return EditorState.create({
    doc: content,
    extensions: buildExtensions(actions),
  });
}

export function createEditor(
  parent: HTMLElement,
  content: string,
  actions: EditorActions,
  language: 'tex' | 'md',
): EditorView {
  const state = createEditorState(content, actions, language);
  const view = new EditorView({ state, parent });
  view.focus();
  return view;
}
```

The `_language` parameter is intentionally unused this phase (still always tex). Phase 7 wires it into `buildExtensions`.

### Task 2.6: Build and smoke test

- [ ] **Step 1: Type-check**

Run: `npx tsc --noEmit`
Expected: clean.

- [ ] **Step 2: Build**

Run: `npm run build`
Expected: clean.

- [ ] **Step 3: Manual smoke test (optional)**

```bash
npm run package && code --install-extension chalk-0.1.0.vsix --force
```

Open `test/fixtures/smoke.tex`. Verify math renders. Verify hsnips still triggers (if a `latex.hsnips` exists).

### Task 2.7: Commit Phase 2

- [ ] **Step 1: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: introduce LanguageProfile abstraction

Extract language-specific data (viewType, allowed commands, hsnips loader,
scope candidates) into a LanguageProfile object passed to the provider
constructor. Provider class renamed from ChalkTexEditorProvider to
ChalkEditorProvider. Init message now carries a language field. Tex
behavior unchanged; markdown profile arrives in Phase 6.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3: Parameterize theme-reader by scope candidates

Today `SCOPE_CANDIDATES` lives at module scope in `theme-reader.ts`. Move it into language profiles (already done for tex in Phase 2.2) and make `readThemeColors` take the scope map as input. The diagnostics command uses the active document's profile.

### Task 3.1: Make `readThemeColors` accept a scope map argument

**Files:**
- Modify: `src/extension/theme-reader.ts`

- [ ] **Step 1: Delete the in-file `SCOPE_CANDIDATES` constant**

Delete lines 22-92 (the entire `SCOPE_CANDIDATES` definition). The `ThemeColors` interface (lines 5-19) stays — same fields, same shape.

- [ ] **Step 2: Add a parameter to `readThemeColors` and `diagnoseThemeResolution`**

The function signatures change to take a scope-candidates map. Use the existing `ThemeColors` keys as a structural type guarantee:

```ts
type ScopeCandidates = Record<keyof ThemeColors, string[]>;

export async function readThemeColors(
  scopes: ScopeCandidates,
): Promise<ThemeColors | null> {
  const diag = await diagnoseThemeResolution(scopes);
  return diag.colors;
}

export async function diagnoseThemeResolution(
  scopes: ScopeCandidates,
): Promise<ThemeDiagnostics> {
  const diag: ThemeDiagnostics = {
    themeLabel: null,
    themePath: null,
    tokenColorCount: 0,
    colors: null,
    matchedScopes: {},
  };
  try {
    diag.themeLabel =
      vscode.workspace.getConfiguration('workbench').get<string>('colorTheme') ??
      null;
    if (!diag.themeLabel) return diag;

    diag.themePath = findThemeFilePath(diag.themeLabel);
    if (!diag.themePath) return diag;

    const tokens = await loadMergedTokenColors(diag.themePath);
    diag.tokenColorCount = tokens.length;
    const { colors, matched } = resolveAllWithProvenance(tokens, scopes);
    diag.colors = colors;
    diag.matchedScopes = matched;
    return diag;
  } catch (e) {
    diag.error = e instanceof Error ? e.message : String(e);
    return diag;
  }
}
```

- [ ] **Step 3: Update `resolveAllWithProvenance` signature**

```ts
function resolveAllWithProvenance(
  tokens: RawTokenColor[],
  scopes: ScopeCandidates,
): {
  colors: ThemeColors;
  matched: Partial<Record<keyof ThemeColors, string | null>>;
} {
  const colors: Partial<ThemeColors> = {};
  const matched: Partial<Record<keyof ThemeColors, string | null>> = {};
  for (const key of Object.keys(scopes) as (keyof ThemeColors)[]) {
    colors[key] = null;
    matched[key] = null;
    for (const scope of scopes[key]) {
      const color = resolveScopeColor(scope, tokens);
      if (color) {
        colors[key] = color;
        matched[key] = scope;
        break;
      }
    }
  }
  return { colors: colors as ThemeColors, matched };
}
```

- [ ] **Step 4: Update `LanguageProfile.themeScopeCandidates` type to match**

In `src/extension/languages/types.ts`, change `themeScopeCandidates` from `Record<string, string[]>` to a more precise shape that matches `ThemeColors`:

```ts
import type { ThemeColors } from '../theme-reader';

// ...
themeScopeCandidates: Record<keyof ThemeColors, string[]>;
```

This requires `ThemeColors` to be exported. Confirm — line 10 of `theme-reader.ts` has `export interface ThemeColors`.

### Task 3.2: Update provider call sites

**Files:**
- Modify: `src/extension/chalk-editor-provider.ts:69`

- [ ] **Step 1: Pass profile scopes into `readThemeColors`**

Change:
```ts
const postThemeColors = async (): Promise<void> => {
  const colors = await readThemeColors();
  if (!colors) return;
  webviewPanel.webview.postMessage({ type: 'theme-colors', colors });
};
```
to:
```ts
const postThemeColors = async (): Promise<void> => {
  const colors = await readThemeColors(this.profile.themeScopeCandidates);
  if (!colors) return;
  webviewPanel.webview.postMessage({ type: 'theme-colors', colors });
};
```

### Task 3.3: Update `chalk.diagnoseTheme` command

**Files:**
- Modify: `src/extension/index.ts`

- [ ] **Step 1: Use the active document's profile**

The diagnoseTheme command currently calls `diagnoseThemeResolution()` with no argument. Now it needs a profile. For now (only tex registered), use `texProfile.themeScopeCandidates`. After Phase 8, we'll dispatch on the active editor's viewType.

In `src/extension/index.ts`, update the command registration:

```ts
vscode.commands.registerCommand('chalk.diagnoseTheme', async () => {
  const diag = await diagnoseThemeResolution(texProfile.themeScopeCandidates);
  diagChannel.clear();
  diagChannel.appendLine(JSON.stringify(diag, null, 2));
  diagChannel.show(true);
}),
```

(Phase 8 revisits this to switch profiles by active editor.)

### Task 3.4: Run tests

- [ ] **Step 1: Verify the existing theme-reader test still passes**

The existing `test/unit/theme-reader.test.ts` tests `resolveScopeColor` directly, which is unchanged. Run:

```bash
npm test
```
Expected: pass.

### Task 3.5: Build, smoke test, commit Phase 3

- [ ] **Step 1: Build**

Run: `npm run build`
Expected: clean.

- [ ] **Step 2: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: parameterize theme-reader by scope candidates

readThemeColors and diagnoseThemeResolution now take the scope-candidate
map as an argument. SCOPE_CANDIDATES moves out of theme-reader.ts and
into the tex language profile (introduced in Phase 2). This makes the
reader reusable across languages — Phase 6 plugs in MD_SCOPE_CANDIDATES.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4: Lift hsnips math-context as injected callback

`hsnipsExtension()` currently imports `scanMathRegions` from `tex-math.ts`. Make it a callback so md can plug in its own detector. After this phase the engine is language-agnostic.

### Task 4.1: Export `isInMathContextTex` from tex-math.ts

**Files:**
- Modify: `src/webview/editor/tex-math.ts`

- [ ] **Step 1: Add an exported context-check function**

At the bottom of `tex-math.ts`, after the `texMathPlugin` export, add:

```ts
import type { EditorState as _EditorState } from '@codemirror/state';

/**
 * Returns true when `pos` lies within any math region of the document.
 * Used by the hsnips engine to gate `context math(context)` snippet
 * filters; tex passes this function as the `isInMathContext` callback.
 *
 * O(n) in document length per call — same scanner the math widget pass
 * already runs. Future optimization: lift `scanMathRegions` into a
 * StateField shared by both consumers.
 */
export function isInMathContextTex(state: _EditorState, pos: number): boolean {
  const doc = state.doc.toString();
  const regions = scanMathRegions(doc);
  return regions.some((r) => pos >= r.from && pos <= r.to);
}
```

(`EditorState` is already imported at the top of the file as `EditorState`. The `_EditorState` import alias above is just to avoid collision; you can also reuse the existing import — the function above can simply use `EditorState` directly. The simpler version:)

```ts
export function isInMathContextTex(state: EditorState, pos: number): boolean {
  const doc = state.doc.toString();
  const regions = scanMathRegions(doc);
  return regions.some((r) => pos >= r.from && pos <= r.to);
}
```

### Task 4.2: Make `hsnipsExtension` accept an `isInMathContext` callback

**Files:**
- Modify: `src/webview/editor/hsnips-plugin.ts`

- [ ] **Step 1: Add the callback parameter and remove the tex-math import**

At the top of the file, **delete** line 32:
```ts
import { scanMathRegions } from './tex-math';
```

The local `isCursorInMath` function (lines 106-110) is no longer needed — the callback replaces it. **Delete** lines 104-110 (the section header comment + function).

- [ ] **Step 2: Update `passesContextFilter` to take the callback as parameter**

Replace lines 112-124 with:

```ts
function passesContextFilter(
  snippet: HSnippet,
  state: EditorState,
  pos: number,
  isInMathContext: (state: EditorState, pos: number) => boolean,
): boolean {
  if (!snippet.contextFilter) return true;
  if (snippet.contextFilter.includes('math')) {
    return isInMathContext(state, pos);
  }
  return false;
}
```

- [ ] **Step 3: Thread the callback through `findMatch`**

Replace the `findMatch` signature (line 135-138) and its `passesContextFilter` call (line 147):

```ts
function findMatch(
  state: EditorState,
  snippets: HSnippet[],
  isInMathContext: (state: EditorState, pos: number) => boolean,
): MatchResult | null {
  const pos = state.selection.main.head;
  const line = state.doc.lineAt(pos);
  const lineText = line.text;
  const col = pos - line.from;
  const textUpToCursor = lineText.slice(0, col);

  for (const snippet of snippets) {
    if (!snippet.automatic) continue;
    if (!passesContextFilter(snippet, state, pos, isInMathContext)) continue;
    // ... rest unchanged
```

- [ ] **Step 4: Thread the callback through `autoExpand`**

The `autoExpand` extension currently lives at module scope. It needs the callback. Convert it from a module-level constant to a factory function. Replace lines 350-378:

```ts
function autoExpandFor(
  isInMathContext: (state: EditorState, pos: number) => boolean,
) {
  return EditorView.updateListener.of((update: ViewUpdate) => {
    if (!update.docChanged) return;
    if (isExpanding) return;

    let isKeystroke = false;
    update.transactions.forEach((tr) => {
      tr.changes.iterChanges((_fromA, _toA, _fromB, _toB, inserted) => {
        if (inserted.length >= 1) isKeystroke = true;
      });
    });

    if (!isKeystroke) return;

    const snippets = update.state.field(snippetsField);
    if (snippets.length === 0) return;

    const match = findMatch(update.state, snippets, isInMathContext);
    if (match) {
      requestAnimationFrame(() => expandSnippet(update.view, match));
    }
  });
}
```

- [ ] **Step 5: Update the public `hsnipsExtension` signature**

Replace lines 452-462:

```ts
export interface HsnipsOptions {
  /** Returns true when `pos` lies inside a math region in `state`. The
   *  hsnips engine uses this to evaluate the `math(context)` filter from
   *  .hsnips files. Tex passes `isInMathContextTex` from `tex-math.ts`;
   *  md passes a lezer-tree query for `InlineMath`/`DisplayMath` nodes. */
  isInMathContext: (state: EditorState, pos: number) => boolean;
}

export function hsnipsExtension(opts: HsnipsOptions): Extension {
  return [
    snippetsField,
    sessionField,
    sessionDecorations,
    keymap.of(hsnipsKeymap),
    autoExpandFor(opts.isInMathContext),
    hsnipsTheme,
  ];
}
```

### Task 4.3: Wire the callback into setup.ts

**Files:**
- Modify: `src/webview/editor/setup.ts`

- [ ] **Step 1: Add the import and pass the callback**

At the top of `setup.ts`, change:
```ts
import { texMathPlugin } from './tex-math';
```
to:
```ts
import { texMathPlugin, isInMathContextTex } from './tex-math';
```

In `buildExtensions`, replace `hsnipsExtension(),` with:
```ts
hsnipsExtension({ isInMathContext: isInMathContextTex }),
```

### Task 4.4: Build and smoke test snippets

- [ ] **Step 1: Build**

Run: `npm run build`
Expected: clean.

- [ ] **Step 2: Smoke test**

```bash
npm run package && code --install-extension chalk-0.1.0.vsix --force
```

Open `test/fixtures/smoke.tex`. Inside an inline `$…$`, type a snippet trigger from your `latex.hsnips` (e.g., `fr`). Confirm expansion still works. Outside math, type `fr` — confirm it does NOT expand (since it has `context math(context)`).

### Task 4.5: Commit Phase 4

- [ ] **Step 1: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: hsnips math-context as injected callback

hsnipsExtension now takes an isInMathContext callback rather than
importing scanMathRegions directly. Tex passes isInMathContextTex
(exported from tex-math.ts). Markdown will pass a lezer-tree query
in Phase 6. Engine is now fully language-agnostic.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 5: Rename `syntax-highlight.ts` to `tex-syntax-highlight.ts`

`syntax-highlight.ts` contains `texHighlightStyle` — tex-specific. Renaming makes the language affinity explicit and avoids collision with anything markdown-side might bring.

### Task 5.1: Rename the file and update the import

**Files:**
- Rename: `src/webview/editor/syntax-highlight.ts` → `src/webview/editor/tex-syntax-highlight.ts`
- Modify: `src/webview/editor/setup.ts`

- [ ] **Step 1: Move the file**

```bash
git mv src/webview/editor/syntax-highlight.ts src/webview/editor/tex-syntax-highlight.ts
```

- [ ] **Step 2: Update the import in setup.ts**

Change:
```ts
import { texHighlightStyle } from './syntax-highlight';
```
to:
```ts
import { texHighlightStyle } from './tex-syntax-highlight';
```

### Task 5.2: Build, commit Phase 5

- [ ] **Step 1: Build**

Run: `npm run build`
Expected: clean.

- [ ] **Step 2: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: rename syntax-highlight.ts to tex-syntax-highlight.ts

Makes the language affinity explicit ahead of pulling in markdown's
extensions, which use lezer-markdown's built-in highlighting rather
than a separate HighlightStyle.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 6: Import chalk-md's webview code

Pull in the markdown-specific extensions from the archived chalk-md repo. Add deps. Create the markdown language profile. After this phase the markdown code is present and compiles, but is not yet wired into `setup.ts` or registered as a viewType.

### Task 6.1: Add markdown deps to package.json

**Files:**
- Modify: `package.json`

- [ ] **Step 1: Add to dependencies**

Add to the `"dependencies"` block (after `@codemirror/legacy-modes`):

```json
    "@codemirror/lang-markdown": "^6.5.0",
    "@lezer/markdown": "^1.6.3",
```

- [ ] **Step 2: Install**

Run: `npm install`
Expected: lockfile updated, no errors.

### Task 6.2: Copy `math-plugin.ts` from chalk-md

**Files:**
- Create: `src/webview/editor/md-math-plugin.ts`

- [ ] **Step 1: Copy the file**

```bash
cp /Users/raphaelhuleux/Desktop/04-archives/2026/chalk/src/webview/editor/math-plugin.ts \
   src/webview/editor/md-math-plugin.ts
```

- [ ] **Step 2: Verify imports still resolve**

The chalk-md version imports from `../utils/katex-cache` and `../styles/math.css`. Both paths exist in chalk-tex. No changes needed.

Check by running:
```bash
grep -n "import" src/webview/editor/md-math-plugin.ts | head -20
```

- [ ] **Step 3: Add an `isInMathContextMd` export at the bottom**

Append to `md-math-plugin.ts`:

```ts
import { syntaxTree as _syntaxTree } from '@codemirror/language';

/**
 * Returns true when `pos` lies inside an `InlineMath` or `DisplayMath`
 * node in the markdown syntax tree. Hsnips passes this as the
 * `isInMathContext` callback for the markdown editor.
 */
export function isInMathContextMd(
  state: import('@codemirror/state').EditorState,
  pos: number,
): boolean {
  const tree = _syntaxTree(state);
  const node = tree.resolveInner(pos);
  let n: { name: string; parent: typeof node | null } | null = node;
  while (n) {
    if (n.name === 'InlineMath' || n.name === 'DisplayMath') return true;
    n = n.parent;
  }
  return false;
}
```

(`syntaxTree` is already imported at the top of `md-math-plugin.ts` — you can reuse the existing import and skip the alias.)

### Task 6.3: Copy `live-preview.ts` from chalk-md

**Files:**
- Create: `src/webview/editor/md-live-preview.ts`

- [ ] **Step 1: Copy the file**

```bash
cp /Users/raphaelhuleux/Desktop/04-archives/2026/chalk/src/webview/editor/live-preview.ts \
   src/webview/editor/md-live-preview.ts
```

- [ ] **Step 2: Verify imports**

The file imports from `../api` (via `openExternal`) and `../styles/editor.css`. Both exist.

Check by running:
```bash
grep -n "import" src/webview/editor/md-live-preview.ts | head -10
```

### Task 6.4: Add markdown styles from chalk-md

**Files:**
- Modify: `src/webview/styles/editor.css`

- [ ] **Step 1: Append md-specific CSS**

Read the chalk-md editor.css file at `/Users/raphaelhuleux/Desktop/04-archives/2026/chalk/src/webview/styles/editor.css` and append every block to chalk-tex's `src/webview/styles/editor.css`. The chalk-md file contains `.cm-h1` through `.cm-h6` heading rules, `.cm-live-bold`, `.cm-live-italic`, `.cm-live-link`, `.cm-live-code`, `.cm-live-hr`, `.cm-live-blockquote`, `.cm-live-quote-mark` etc.

These rules use CSS vars `--chalk-heading-1..6`, `--syntax-code-bg`, `--syntax-link`, `--syntax-markup`, `--divider`. The first set (`--chalk-heading-N`) is set by chalk-md's webview-html.ts via inline `<style>`. The others have no producer in chalk-md — they're either dead refs or expected fallbacks. Open the file and copy what's there.

(Note: this is the largest and most uncertain copy. If a particular rule references a CSS var with no fallback chain that ends in a real color, the md preview may render blank text. After Phase 8 smoke testing, fix any visibility issues by adding fallbacks: `var(--chalk-heading-1, var(--vscode-textLink-foreground))` is the chalk-md convention.)

- [ ] **Step 2: Verify chalk-md's expected vars have fallbacks**

For each of `--chalk-heading-N`, `--syntax-code-bg`, `--syntax-link`, `--syntax-markup`, `--divider`, confirm the CSS rule that uses it has a `var(--name, fallback)` form. If not, add `var(--vscode-editor-foreground)` as the fallback.

Specifically, the chalk-md file provides this convention for `.cm-h1`:
```css
.cm-h1 { color: var(--chalk-heading-1, var(--vscode-textLink-foreground)); }
```

Make sure that's preserved for all six heading levels in the appended block.

### Task 6.5: Create the markdown language profile

**Files:**
- Create: `src/extension/languages/markdown.ts`

- [ ] **Step 1: Write the profile**

The markdown profile differs from tex in several ways:
- viewType: `chalk.markdownEditor`
- allowedWebviewCommands: empty (no build command for md)
- themeScopeCandidates: maps `keyword`/`tagName`/`comment` etc. to markdown TextMate scopes (lower-priority than tex's, but populated for the same `ThemeColors` interface)
- loadHsnips: returns the latex.hsnips file (so math snippets work) PLUS optionally a markdown.hsnips file

Note: the `ThemeColors` interface has fields tailored to LaTeX tokens (keyword, tagName, etc.). For markdown, the lezer-markdown highlighting handles syntax colors via CM6 tags automatically — we don't really need theme-derived colors for those tags. BUT we DO need heading colors for the `.cm-h1`..`.cm-h6` decorations. To keep the existing pipeline simple, this phase has the markdown profile return empty arrays for the standard fields and skip per-heading colors. Phase 7 introduces a separate per-heading channel.

For now (Phase 6), use empty scope arrays for all fields:

```ts
import { existsSync, readFileSync } from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';
import type { LanguageProfile } from './types';
import type { ThemeColors } from '../theme-reader';

const MD_SCOPE_CANDIDATES: Record<keyof ThemeColors, string[]> = {
  keyword: [],
  tagName: [],
  comment: [],
  number: [],
  atom: [],
  bracket: [],
  specialVariable: [],
  invalid: [],
};

/**
 * Loads hsnips for markdown editing. Always tries `latex.hsnips` (because
 * markdown's `$…$` regions use the same LaTeX math snippets) and
 * additionally `markdown.hsnips` if it exists. Returns concatenated text.
 */
function loadMarkdownHsnips(): string | null {
  const config = vscode.workspace.getConfiguration('hsnips');
  const customPath = config.get<string>('hsnipsPath');
  const searchDirs = [
    customPath,
    path.join(process.env.HOME || '', '.config', 'hsnips'),
  ].filter(Boolean) as string[];

  const parts: string[] = [];
  for (const dir of searchDirs) {
    for (const fname of ['latex.hsnips', 'markdown.hsnips']) {
      const filePath = path.join(dir, fname);
      if (existsSync(filePath)) {
        parts.push(readFileSync(filePath, 'utf8'));
      }
    }
    if (parts.length > 0) break;
  }
  return parts.length > 0 ? parts.join('\n') : null;
}

export const markdownProfile: LanguageProfile = {
  id: 'md',
  viewType: 'chalk.markdownEditor',
  allowedWebviewCommands: new Set(),
  themeScopeCandidates: MD_SCOPE_CANDIDATES,
  loadHsnips: loadMarkdownHsnips,
};
```

### Task 6.6: Add a heading-color channel for markdown

The markdown editor needs `--chalk-heading-1..6` CSS vars set from the active theme. Rather than overload `ThemeColors`, add a separate small reader.

**Files:**
- Create: `src/extension/markdown-heading-colors.ts`

- [ ] **Step 1: Write the heading-color reader (port of chalk-md's theme-tokens.ts)**

```ts
import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';

export type HeadingLevel = 1 | 2 | 3 | 4 | 5 | 6;
export type HeadingColors = Partial<Record<HeadingLevel, string>>;

interface TokenColorRule {
  scope?: string | string[];
  settings?: { foreground?: string };
}

interface ThemeJson {
  include?: string;
  tokenColors?: TokenColorRule[];
}

/**
 * Best-effort extraction of the active theme's markdown heading colors.
 * Returns an empty object when the theme is built-in (Dark+/Light+ are
 * not addressable on disk), uses `include:` (not followed), or has no
 * matching rules. Callers should provide CSS-var fallbacks.
 */
export function getMarkdownHeadingColors(): HeadingColors {
  const themeName = vscode.workspace
    .getConfiguration('workbench')
    .get<string>('colorTheme');
  if (!themeName) return {};

  const themePath = findThemePath(themeName);
  if (!themePath) return {};

  const theme = loadThemeJson(themePath);
  if (!theme?.tokenColors) return {};

  const result: HeadingColors = {};
  for (const level of [1, 2, 3, 4, 5, 6] as const) {
    const color = findHeadingColor(theme.tokenColors, level);
    if (color) result[level] = color;
  }
  return result;
}

function findThemePath(themeLabel: string): string | null {
  for (const ext of vscode.extensions.all) {
    const themes = ext.packageJSON?.contributes?.themes as
      | Array<{ label?: string; id?: string; path: string }>
      | undefined;
    if (!Array.isArray(themes)) continue;
    for (const theme of themes) {
      if (theme.label === themeLabel || theme.id === themeLabel) {
        return path.join(ext.extensionPath, theme.path);
      }
    }
  }
  return null;
}

function loadThemeJson(themePath: string): ThemeJson | null {
  try {
    const raw = fs.readFileSync(themePath, 'utf8');
    const stripped = raw
      .replace(/\/\/.*$/gm, '')
      .replace(/\/\*[\s\S]*?\*\//g, '');
    return JSON.parse(stripped) as ThemeJson;
  } catch {
    return null;
  }
}

function findHeadingColor(
  rules: TokenColorRule[],
  level: HeadingLevel,
): string | undefined {
  const target = `heading.${level}.markdown`;
  for (let i = rules.length - 1; i >= 0; i--) {
    const rule = rules[i];
    const fg = rule.settings?.foreground;
    if (!fg) continue;
    const scopes = normalizeScopes(rule.scope);
    if (scopes.some((s) => s.includes(target))) return fg;
  }
  return undefined;
}

function normalizeScopes(scope: string | string[] | undefined): string[] {
  if (!scope) return [];
  if (Array.isArray(scope)) return scope;
  return scope.split(',').map((s) => s.trim());
}
```

### Task 6.7: Verify everything still compiles

- [ ] **Step 1: Build**

Run: `npm run build`
Expected: clean. The markdown files are not yet imported anywhere outside the host loader, so nothing in the webview bundle should reference them yet.

- [ ] **Step 2: Type check**

Run: `npx tsc --noEmit`
Expected: clean.

### Task 6.8: Commit Phase 6

- [ ] **Step 1: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat: import markdown language module from archived chalk-md

Adds @codemirror/lang-markdown and @lezer/markdown deps. Copies
math-plugin.ts and live-preview.ts from the archived chalk-md repo into
src/webview/editor/md-math-plugin.ts and md-live-preview.ts. Adds
markdownProfile in src/extension/languages/markdown.ts and a separate
markdown-heading-colors.ts reader. Adds heading + live-preview CSS
rules. Markdown is not yet wired into setup.ts or registered as a
viewType — that arrives in Phases 7 and 8.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 7: Wire markdown into setup.ts

`buildExtensions` becomes language-aware. Markdown branch uses `markdown(...)` parser config + `mathPlugin()` + `livePreviewPlugin()` from the imported md files, plus the same shared hsnips engine with the markdown math-context detector.

### Task 7.1: Add `previewCompartment` to theme.ts

**Files:**
- Modify: `src/webview/editor/theme.ts`

- [ ] **Step 1: Export `previewCompartment` (used by md to gate the live-preview)**

Replace lines 11-12 (the existing themeCompartment export and its comment block) with:

```ts
/**
 * Preview compartment — wraps live-preview + math plugins for markdown so
 * they can be toggled off at runtime to reveal raw markdown ("source mode").
 * Tex doesn't use this — math is always on; use VS Code's Reopen With →
 * Text Editor to see raw LaTeX. The compartment is exported anyway so
 * setup.ts can wrap md plugins in it.
 */
export const previewCompartment = new Compartment();

/**
 * Theme compartment — kept for future runtime theme swaps.
 */
export const themeCompartment = new Compartment();
```

### Task 7.2: Update buildExtensions to take a `language` parameter

**Files:**
- Modify: `src/webview/editor/setup.ts`

- [ ] **Step 1: Refactor the imports section**

Replace the entire imports section with:

```ts
import { EditorState } from '@codemirror/state';
import {
  EditorView,
  keymap,
  placeholder,
  drawSelection,
  highlightSpecialChars,
  lineNumbers,
} from '@codemirror/view';
import {
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
} from '@codemirror/commands';
import {
  bracketMatching,
  indentUnit,
  StreamLanguage,
  syntaxHighlighting,
} from '@codemirror/language';
import {
  acceptCompletion,
  closeBrackets,
  closeBracketsKeymap,
} from '@codemirror/autocomplete';
import {
  searchKeymap,
  highlightSelectionMatches,
} from '@codemirror/search';
import { stex } from '@codemirror/legacy-modes/mode/stex';
import { markdown } from '@codemirror/lang-markdown';
import { Strikethrough, TaskList } from '@lezer/markdown';

import { themeCompartment, previewCompartment, vsCodeTheme } from './theme';
import { chalkKeymap, EditorActions } from './keymap';
import { hsnipsExtension, hsnipsKeymap } from './hsnips-plugin';

import { texMathPlugin, isInMathContextTex } from './tex-math';
import { texHighlightStyle } from './tex-syntax-highlight';
import { latexCompletionExtension } from './latex-completions';

import { mathPlugin, mathSyntax, isInMathContextMd } from './md-math-plugin';
import { livePreviewPlugin } from './md-live-preview';
```

(`mathSyntax` is the lezer markdown extension exported from chalk-md's math-plugin.ts. Verify the export name by grepping `src/webview/editor/md-math-plugin.ts` for `export.*mathSyntax`.)

- [ ] **Step 2: Replace the buildExtensions function with a language switch**

Replace the entire `buildExtensions` function with:

```ts
type Language = 'tex' | 'md';

export function buildExtensions(
  actions: EditorActions,
  language: Language,
): Array<unknown> {
  const shared = [
    keymap.of(hsnipsKeymap),
    keymap.of([{ key: 'Tab', run: acceptCompletion }]),
    keymap.of(chalkKeymap()),

    keymap.of([indentWithTab]),
    keymap.of(closeBracketsKeymap),
    keymap.of(historyKeymap),
    keymap.of(searchKeymap),
    keymap.of(defaultKeymap),

    lineNumbers(),
    history(),
    bracketMatching(),
    closeBrackets(),
    drawSelection(),
    highlightSpecialChars(),
    highlightSelectionMatches(),

    indentUnit.of('    '),
    EditorView.lineWrapping,

    EditorView.updateListener.of((update) => {
      if (update.docChanged) {
        actions.onContentChange(update.state.doc.toString());
      }
    }),

    themeCompartment.of(vsCodeTheme()),
  ];

  if (language === 'tex') {
    return [
      ...shared,
      StreamLanguage.define(stex),
      syntaxHighlighting(texHighlightStyle),
      texMathPlugin(),
      hsnipsExtension({ isInMathContext: isInMathContextTex }),
      latexCompletionExtension(),
      placeholder('% Start typing LaTeX…'),
    ];
  }

  // language === 'md' — note: no latexCompletionExtension; markdown
  // doesn't get LaTeX env/command autocomplete.
  return [
    ...shared,
    markdown({ extensions: [mathSyntax, Strikethrough, TaskList] }),
    previewCompartment.of([mathPlugin(), livePreviewPlugin()]),
    hsnipsExtension({ isInMathContext: isInMathContextMd }),
    placeholder('Start typing…'),
  ];
}
```

- [ ] **Step 3: Update `createEditorState` and `createEditor` to pass language through**

Replace the two functions at the bottom of the file:

```ts
export function createEditorState(
  content: string,
  actions: EditorActions,
  language: Language,
): EditorState {
  return EditorState.create({
    doc: content,
    extensions: buildExtensions(actions, language),
  });
}

export function createEditor(
  parent: HTMLElement,
  content: string,
  actions: EditorActions,
  language: Language,
): EditorView {
  const state = createEditorState(content, actions, language);
  const view = new EditorView({ state, parent });
  view.focus();
  return view;
}
```

### Task 7.3: Verify chalk-md's `mathSyntax` and `livePreviewPlugin` are properly exported

**Files:**
- Read: `src/webview/editor/md-math-plugin.ts`
- Read: `src/webview/editor/md-live-preview.ts`

- [ ] **Step 1: Confirm exports**

Run: `grep -n "^export" src/webview/editor/md-math-plugin.ts src/webview/editor/md-live-preview.ts`

Expected: matches for `mathSyntax`, `mathPlugin`, `isInMathContextMd` in md-math-plugin.ts; `livePreviewPlugin` in md-live-preview.ts.

If any are missing, look in the file for `function …` or `const …` declarations and add `export` to them. Specifically:
- `livePreviewPlugin` should be the single public export from md-live-preview.ts.
- `mathSyntax` (the lezer InlineMath/DisplayMath parser config) and `mathPlugin` (the CM6 extension array) are both expected exports from md-math-plugin.ts.

### Task 7.4: Build to verify webview bundles cleanly

- [ ] **Step 1: Build**

Run: `npm run build`
Expected: clean. If esbuild warns about a missing import, it'll point to the offending file.

- [ ] **Step 2: Type check**

Run: `npx tsc --noEmit`
Expected: clean.

### Task 7.5: Commit Phase 7

- [ ] **Step 1: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat: wire markdown editor into setup.ts

buildExtensions now takes a language parameter and branches between tex
and md arms. Tex uses stex + texMathPlugin + hsnips with isInMathContextTex.
Md uses markdown(...) + mathPlugin + livePreviewPlugin in a preview
compartment + hsnips with isInMathContextMd. previewCompartment exported
from theme.ts. Markdown is now buildable but not yet registered.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 8: Register markdown viewType + smoke test both

Add the `chalk.markdownEditor` custom-editor entry. Wire the host to register both providers, post heading colors for md, and dispatch the diagnoseTheme command per active editor.

### Task 8.1: Update package.json customEditors and keybindings

**Files:**
- Modify: `package.json`

- [ ] **Step 1: Add the markdown viewType entry**

Update the `"customEditors"` array to:

```json
    "customEditors": [
      {
        "viewType": "chalk.texEditor",
        "displayName": "Chalk",
        "selector": [{ "filenamePattern": "*.tex" }],
        "priority": "default"
      },
      {
        "viewType": "chalk.markdownEditor",
        "displayName": "Chalk",
        "selector": [{ "filenamePattern": "*.md" }],
        "priority": "default"
      }
    ],
```

- [ ] **Step 2: Add the markdown reopen keybinding**

Update the `"keybindings"` array to also gate on `.md`:

```json
    "keybindings": [
      {
        "command": "workbench.action.reopenWithEditor",
        "key": "cmd+shift+;",
        "mac": "cmd+shift+;",
        "when": "resourceExtname == .tex || resourceExtname == .md"
      },
      {
        "command": "chalk.build",
        "key": "cmd+alt+b",
        "mac": "cmd+alt+b",
        "when": "activeCustomEditorId == 'chalk.texEditor'"
      }
    ]
```

The `chalk.build` keybinding intentionally stays gated to the tex editor.

### Task 8.2: Update extension/index.ts to register both providers

**Files:**
- Modify: `src/extension/index.ts`

- [ ] **Step 1: Register both providers**

Replace the `activate` body with:

```ts
import * as vscode from 'vscode';
import { ChalkEditorProvider } from './chalk-editor-provider';
import { buildWithWorkshop } from './workshop-bridge';
import { diagnoseThemeResolution } from './theme-reader';
import { texProfile } from './languages/tex';
import { markdownProfile } from './languages/markdown';

export function activate(context: vscode.ExtensionContext): void {
  const diagChannel = vscode.window.createOutputChannel('Chalk');

  const editorOptions = {
    webviewOptions: {
      retainContextWhenHidden: true,
    },
    supportsMultipleEditorsPerDocument: false,
  };

  context.subscriptions.push(
    vscode.window.registerCustomEditorProvider(
      texProfile.viewType,
      new ChalkEditorProvider(context, texProfile),
      editorOptions,
    ),
    vscode.window.registerCustomEditorProvider(
      markdownProfile.viewType,
      new ChalkEditorProvider(context, markdownProfile),
      editorOptions,
    ),
    vscode.commands.registerCommand('chalk.build', buildWithWorkshop),
    vscode.commands.registerCommand('chalk.diagnoseTheme', async () => {
      // Pick the profile that matches the currently-focused custom editor;
      // fall back to tex.
      const tab = vscode.window.tabGroups.activeTabGroup.activeTab;
      const profile =
        tab?.input instanceof vscode.TabInputCustom &&
        tab.input.viewType === markdownProfile.viewType
          ? markdownProfile
          : texProfile;
      const diag = await diagnoseThemeResolution(profile.themeScopeCandidates);
      diagChannel.clear();
      diagChannel.appendLine(JSON.stringify(diag, null, 2));
      diagChannel.show(true);
    }),
    diagChannel,
  );
}

export function deactivate(): void {
  // Provider subscriptions are disposed via context.subscriptions.
}
```

### Task 8.3: Send heading colors for the markdown editor

**Files:**
- Modify: `src/extension/chalk-editor-provider.ts`
- Modify: `src/webview/index.ts`

- [ ] **Step 1: Add heading-color posting in the provider**

In `src/extension/chalk-editor-provider.ts`, add a new import:
```ts
import { getMarkdownHeadingColors } from './markdown-heading-colors';
```

Add a `postHeadingColors` helper next to `postThemeColors`:
```ts
const postHeadingColors = (): void => {
  if (this.profile.id !== 'md') return;
  const colors = getMarkdownHeadingColors();
  webviewPanel.webview.postMessage({ type: 'heading-colors', colors });
};
```

In the `'ready'` case, after `void postThemeColors();`, add:
```ts
postHeadingColors();
```

In the `themeSub` callback (where you currently call `postThemeColors`), also call `postHeadingColors`:
```ts
const themeSub = vscode.window.onDidChangeActiveColorTheme(() => {
  if (webviewReady) {
    void postThemeColors();
    postHeadingColors();
  }
});
```

- [ ] **Step 2: Webview — handle the new message**

In `src/webview/index.ts`, extend the `ExtensionMessage` union:

```ts
type HeadingColors = Partial<Record<1 | 2 | 3 | 4 | 5 | 6, string>>;

type ExtensionMessage =
  | { type: 'init'; text: string; language: Language }
  | { type: 'update'; text: string }
  | { type: 'theme-colors'; colors: ThemeColors }
  | { type: 'heading-colors'; colors: HeadingColors }
  | { type: 'hsnips'; content: string };
```

Add the case in `handleMessage`:
```ts
case 'heading-colors': {
  const root = document.documentElement;
  for (const level of [1, 2, 3, 4, 5, 6] as const) {
    const c = msg.colors[level];
    if (c) root.style.setProperty(`--chalk-heading-${level}`, c);
    else root.style.removeProperty(`--chalk-heading-${level}`);
  }
  return;
}
```

### Task 8.4: Add a markdown smoke fixture

**Files:**
- Create: `test/fixtures/smoke.md`

- [ ] **Step 1: Write the fixture**

```md
# Chalk markdown smoke test

A heading at level 1. **Bold text**, *italic text*, and `inline code`.

Inline math: $a^2 + b^2 = c^2$ should render.

Display math:

$$
\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
$$

A list:

- first
- second
- third

A [link](https://example.com).

A literal dollar: \$5 (should NOT be math).

---

## Heading 2

Another paragraph.
```

### Task 8.5: Build, package, install, and smoke test BOTH file types

- [ ] **Step 1: Build and package**

```bash
npm run build
npm run package
```

Expected: `chalk-0.1.0.vsix` produced.

- [ ] **Step 2: Install**

```bash
code --install-extension chalk-0.1.0.vsix --force
```

- [ ] **Step 3: Smoke test tex**

Reload VS Code window. Open `test/fixtures/smoke.tex`. Verify:
1. Inline math renders (`$a^2 + b^2 = c^2$`)
2. Display math renders (`$$…$$`, `\[…\]`, `\begin{equation}`)
3. Cursor inside a math region reveals raw source
4. Hsnips trigger inside math expands (assuming `~/.config/hsnips/latex.hsnips` exists)
5. Cmd+Alt+B fires the build command (it'll still fail per KNOWN_ISSUES.md — verify the command is at least dispatched)
6. Cmd+Shift+; opens the Reopen With picker

- [ ] **Step 4: Smoke test md**

Open `test/fixtures/smoke.md`. Verify:
1. Headings render bold + colored (`# Chalk…`, `## Heading 2`)
2. Bold/italic/strikethrough render with their respective decorations
3. Inline math renders (`$a^2+b^2=c^2$`)
4. Display math renders (`$$…$$`)
5. Cursor inside math reveals raw source
6. Hsnips expands inside `$…$` regions
7. Cmd+Shift+; opens the Reopen With picker
8. Cmd+Alt+B does NOT fire build (since the keybinding is tex-only)
9. The `\$5` literal dollar does NOT render as math

- [ ] **Step 5: Theme switch test**

In VS Code: `Preferences → Color Theme` → switch from your current theme to a different one. Verify:
1. The tex editor's syntax colors update (commands, environments, comments)
2. The md editor's heading colors update

If colors don't update for md, check the chalk-editor-provider's `themeSub` is calling `postHeadingColors()`.

### Task 8.6: Commit Phase 8

- [ ] **Step 1: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat: register markdown custom editor

Adds chalk.markdownEditor viewType for *.md files. Both providers register
from one activate(); the diagnoseTheme command picks the profile based on
the active tab's viewType. Webview now handles a heading-colors message
to set --chalk-heading-N CSS vars for markdown's heading decorations.
test/fixtures/smoke.md added.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 9: Markdown hsnips support and unit tests

The markdown profile already loads `latex.hsnips` (since math snippets work in md's `$…$`) plus optional `markdown.hsnips`. Add a unit test for the markdown context detector and verify expansion in a real `.md` file.

### Task 9.1: Add unit test for `isInMathContextMd`

**Files:**
- Create: `test/unit/md-math-context.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from 'vitest';
import { EditorState } from '@codemirror/state';
import { markdown } from '@codemirror/lang-markdown';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { mathSyntax, isInMathContextMd } from '../../src/webview/editor/md-math-plugin';

function makeState(doc: string): EditorState {
  const state = EditorState.create({
    doc,
    extensions: [markdown({ extensions: [mathSyntax] })],
  });
  // Force the parser to fully parse the document so syntaxTree() returns
  // the complete tree synchronously.
  ensureSyntaxTree(state, state.doc.length, /* timeout */ 5000);
  return state;
}

describe('isInMathContextMd', () => {
  it('returns true inside an inline math span', () => {
    const state = makeState('hello $x^2$ world');
    // Position is between the dollar signs.
    expect(isInMathContextMd(state, 8)).toBe(true);
  });

  it('returns false outside math', () => {
    const state = makeState('hello $x^2$ world');
    expect(isInMathContextMd(state, 1)).toBe(false);
    expect(isInMathContextMd(state, 14)).toBe(false);
  });

  it('returns true inside a display math block', () => {
    const state = makeState('text\n\n$$\nx^2\n$$\n\nmore');
    // Position is on the `x^2` line.
    const idx = state.doc.toString().indexOf('x^2');
    expect(isInMathContextMd(state, idx + 1)).toBe(true);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails or passes**

Run: `npm test -- md-math-context`
Expected: tests pass (the implementation already exists in md-math-plugin.ts).

If they fail: the lezer tree might not parse `mathSyntax` correctly, or `ensureSyntaxTree` may not have been called with a long-enough timeout. Adjust.

### Task 9.2: Manually verify markdown hsnips expansion

- [ ] **Step 1: Confirm a markdown.hsnips example**

If your `~/.config/hsnips/markdown.hsnips` doesn't exist yet, create one with a sample non-math snippet:

```
priority 100
snippet ]] "Markdown link" iA
[$1]($2)$0
endsnippet
```

(`iA` means: inword, automatic — fires inside a word too.)

- [ ] **Step 2: Reload and test**

Reload VS Code. Open `test/fixtures/smoke.md`. Type `]]` somewhere outside math — confirm it expands to `[](^^)` with cursor positioned at the first tab stop.

Inside `$…$`, type `fr` (assuming `latex.hsnips` has the standard `\frac` snippet). Confirm it expands.

### Task 9.3: Commit Phase 9

- [ ] **Step 1: Run all tests**

Run: `npm test`
Expected: all pass.

- [ ] **Step 2: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
test: unit test for markdown math-context detector

Adds test/unit/md-math-context.test.ts verifying that isInMathContextMd
correctly identifies positions inside InlineMath and DisplayMath nodes
in the lezer-markdown tree. Manual smoke confirmed hsnips expansion in
both math and non-math contexts within .md files.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 10: Final docs and packaging

Update CLAUDE.md to describe both languages, bump version, run final smoke test, package the release.

### Task 10.1: Rewrite CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Write the merged description**

Keep the file under 100 lines per the user's global rule. Replace the entire file with:

```markdown
# Chalk

Live-preview editor for `.tex` and `.md` files with first-class math
support, packaged as a VS Code custom editor extension.

Two `viewType`s share one host shell, KaTeX cache, theme reader, and
hsnips snippet engine; per-language CodeMirror extensions diverge in
[setup.ts](src/webview/editor/setup.ts).

## Status (2026-04-25)

Merged from chalk-tex (LaTeX-only) and the archived chalk-md. Tex math
preview works. Markdown headings + math + live-preview work. Hsnips
shared across both. LaTeX Workshop bridge for `chalk.build`
(`Cmd+Alt+B`) is **non-functional** — see [KNOWN_ISSUES.md](KNOWN_ISSUES.md).

## Architecture

Extension host (Node) ↔ webview (Chromium sandbox) via `postMessage`:
- `extension → webview`: `init({text, language})`, `update({text})`,
  `theme-colors({colors})`, `heading-colors({colors})` (md only),
  `hsnips({content})`
- `webview → extension`: `ready`, `edit({text})`,
  `open-external({url})`, `command({id})`

`command` is whitelisted per language profile via
`allowedWebviewCommands`. Tex allows `chalk.build`; md allows nothing.

Sync strategy: eager full-text replace. `isApplyingOwnEdit` flag prevents
edit→WorkspaceEdit→onDidChangeTextDocument→update→edit loops.

Activation: `.tex` → `chalk.texEditor`, `.md` → `chalk.markdownEditor`,
both `priority: "default"`. `Cmd+Shift+;` reopens with VS Code's picker.

## Language seam

[src/extension/languages/](src/extension/languages/) holds one
`LanguageProfile` per file type:
- `tex.ts` — viewType, build command, latex.hsnips loader, tex scope candidates
- `markdown.ts` — viewType, no commands, latex+markdown hsnips loader, empty scopes (md uses heading-color channel separately)

The provider class is generic over the profile. The webview's
[setup.ts](src/webview/editor/setup.ts) branches on the `language` field
in the init message: `tex` arm uses `stex` + `texMathPlugin` + tex syntax
highlight; `md` arm uses `markdown(...)` + `mathPlugin` + `livePreviewPlugin`
in a preview compartment.

The shared hsnips engine ([hsnips-plugin.ts](src/webview/editor/hsnips-plugin.ts))
takes an `isInMathContext` callback at construction time — tex passes
`isInMathContextTex` (regex/character walker), md passes `isInMathContextMd`
(lezer-tree query). All trigger matching, body parsing, tab-stops are
language-agnostic.

## Hsnips

Standalone implementation of the HyperSnips file format (no dependency
on the `draivin.vscode-hsnips` extension). The engine is fully
self-contained in CM6 — VS Code's native snippet machinery doesn't run
inside custom-editor webviews. Inline JS blocks (\`\`…\`\`) in `.hsnips`
files are parsed but discarded; only static-body snippets are supported.
Reads from `hsnips.hsnipsPath` setting first, then `~/.config/hsnips`.

## Guardrails

- Markdown live-preview shouldn't add features beyond what chalk-md
  shipped (headings, bold, italic, link, code, strikethrough, hr,
  blockquote, math). Don't expand to tables, footnotes, MDX, etc.
  without a concrete need.
- Don't add LaTeX compilation, bibliography, or other features that
  [LaTeX Workshop](https://github.com/James-Yu/LaTeX-Workshop) provides.
- Theme-color reading: tex uses syntax-tag scopes
  ([theme-reader.ts](src/extension/theme-reader.ts)); md uses heading-N
  scopes ([markdown-heading-colors.ts](src/extension/markdown-heading-colors.ts)).
  The two paths are intentionally separate — they output different CSS
  var families and serve different decoration systems.

## Build & install

```bash
npm install
npm run build          # esbuild: extension + webview
npm run package        # produces chalk-X.Y.Z.vsix
code --install-extension chalk-0.2.0.vsix --force
```

Test fixtures: [test/fixtures/smoke.tex](test/fixtures/smoke.tex),
[test/fixtures/smoke.md](test/fixtures/smoke.md).
```

### Task 10.2: Bump version to 0.2.0

**Files:**
- Modify: `package.json:5`

- [ ] **Step 1: Update version**

Change `"version": "0.1.0"` to `"version": "0.2.0"`.

### Task 10.3: Final smoke test

- [ ] **Step 1: Build and package**

```bash
npm run build && npm run package
```
Expected: `chalk-0.2.0.vsix` produced, no errors or warnings.

- [ ] **Step 2: Reinstall**

```bash
code --install-extension chalk-0.2.0.vsix --force
```

- [ ] **Step 3: Run the full smoke checklist**

Open `test/fixtures/smoke.tex`:
- [ ] Inline math `$…$` renders
- [ ] Display math `$$…$$`, `\[…\]`, `\begin{equation}` render
- [ ] Cursor in math reveals source
- [ ] Hsnips expand inside math
- [ ] Theme syntax colors apply (commands, environments, comments)
- [ ] Cmd+Shift+; opens Reopen With picker
- [ ] Cmd+Alt+B fires (build command attempted; failure per KNOWN_ISSUES is OK)

Open `test/fixtures/smoke.md`:
- [ ] Headings render bold + colored
- [ ] Bold/italic/strikethrough decorations apply
- [ ] Inline math `$…$` renders
- [ ] Display math `$$…$$` renders
- [ ] Cursor in math reveals source
- [ ] Hsnips expand inside math
- [ ] Hsnips expand outside math (if markdown.hsnips defines non-math snippets)
- [ ] Cmd+Shift+; opens Reopen With picker
- [ ] Cmd+Alt+B does NOT fire build (correctly gated to tex)

Switch theme:
- [ ] Tex syntax colors update
- [ ] Md heading colors update

- [ ] **Step 4: Run unit tests**

Run: `npm test`
Expected: all pass.

### Task 10.4: Commit Phase 10

- [ ] **Step 1: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
chore: docs and v0.2.0 for merged chalk extension

Rewrites CLAUDE.md to describe the merged architecture (one provider, two
viewTypes, shared shell, language profiles, hsnips with injected
isInMathContext). Bumps version to 0.2.0 reflecting the markdown addition.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review checklist

Run through this before declaring the plan complete.

**Spec coverage:**
- [x] Two viewTypes registered in package.json — Phase 8.1
- [x] One ChalkEditorProvider class with LanguageProfile constructor — Phase 2.3
- [x] Shared host shell (sync flag, ready/init handshake, postMessage) — preserved through all phases
- [x] Shared KaTeX cache — already shared (single katex-cache.ts file used by both math implementations)
- [x] Shared hsnips engine with injected isInMathContext — Phase 4
- [x] Per-language CM6 extensions — Phase 7.2 (the language switch)
- [x] Theme-color reading parameterized — Phase 3
- [x] Markdown heading colors via separate channel — Phase 6.6, 8.3
- [x] Tex still works at every commit — verified by Phase 0.7, 1.5, 2.6, 3.5, 4.4, 7.4 smoke tests
- [x] Md works after Phase 8 — verified by Phase 8.5
- [x] Hsnips works in both — verified by Phase 9
- [x] Final .vsix produced — Phase 10.3
- [x] Pre-merge cleanup of debug logs / dead code — Phase 0
- [x] Workshop bridge stays tex-only and gated — Phase 1.2 step 2 + Phase 8.1 keybinding scope

**Type consistency:**
- `LanguageProfile` shape used consistently in `tex.ts`, `markdown.ts`, and the provider — all use same field names (`id`, `viewType`, `allowedWebviewCommands`, `themeScopeCandidates`, `loadHsnips`).
- `Language = 'tex' | 'md'` used in both setup.ts and the init-message type.
- `isInMathContext` callback signature `(state: EditorState, pos: number) => boolean` matches in tex-math.ts (`isInMathContextTex`), md-math-plugin.ts (`isInMathContextMd`), and hsnips-plugin.ts consumer.
- `ThemeColors` keys match between theme-reader.ts and the scope-candidates map in tex.ts/markdown.ts.

**No placeholders:**
- Every code block contains real code, not `// TODO` or "implement later."
- Every `git mv` uses real paths.
- Every `bash` command can be copy-pasted as-is.

**Known unknowns flagged in the plan:**
- Phase 6.4 mentions that the chalk-md `editor.css` block uses some CSS vars (`--syntax-code-bg`, `--syntax-link`, etc.) without producers — flagged for after-Phase-8 visual verification.
- Phase 7.3 has a verification step ensuring `mathSyntax` is exported from md-math-plugin.ts — if the chalk-md original didn't export it, an `export` keyword needs to be added. The plan includes this check rather than assuming.

**Out of scope (explicitly):**
- Workshop-bridge fix — separate effort, tracked in KNOWN_ISSUES.md.
- Refactoring math-region scanning into a shared StateField — flagged as future optimization in the existing tex-math.ts comment, not part of this merge.
- Marketplace publishing — extension stays `private: true` and locally installed.
- Renaming the publisher or extension ID after install — would strand existing users.
