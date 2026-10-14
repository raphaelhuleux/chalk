# Snippet options table — design

Date: 2026-08-02
Status: implemented on `snippet-options-table`. Three behaviors ended up
differing from what is written below; each is marked **As built** where it
belongs, rather than rewritten, so the reasoning stays visible.
Scope: native app (Mac Catalyst) Settings → LaTeX Shortcuts, plus the
editor-core changes the new options require.

## Problem

Settings exposes two of hsnips' capabilities. A user snippet is
`trigger + replacement + autoExpand + mathOnly + enabled`
([UserSnippetStore.swift](../../../mac/ChalkKit/Sources/ChalkKit/UserSnippetStore.swift)),
edited through a pushed form with two fields and three switches
([SnippetEditorViewController.swift](../../../mac/Chalk/Settings/SnippetEditorViewController.swift)).
The parser underneath understands more: word boundary (`w`), line start (`b`),
inverted context (`!math(context)`), and regex triggers. None are reachable.

Built-ins are a second, differently-shaped list: trigger, description, on/off.
[HSnipsCatalog](../../../mac/ChalkKit/Sources/ChalkKit/HSnipsCatalog.swift)
scans only snippet headers, so the app cannot show what a built-in expands to,
and customizing one means retyping it from scratch.

Two visual languages on one screen, and a capability ceiling well below what
the engine supports.

## Shape

One table. Three columns: **Shortcut | Replacement | Options**. Every shortcut
in the app appears as a row, built-ins included. Cells edit in place. The
Options column is tappable state, not typed syntax.

The three-column layout follows a convention common to snippet managers
(Obsidian LaTeX Suite among them). No code, snippet content, or option
vocabulary is taken from any of them. Option letters are hsnips' own —
`A`, `i`, `w`, `b` — which this repo already vendors and attributes
(draivin/hsnips, MIT, see `THIRD-PARTY-NOTICES`).

## Data model

New in ChalkKit (pure Foundation, no UIKit — must stay `swift test`-able):

```swift
public struct SnippetOptions: Codable, Equatable {
    public enum Mode: String, Codable { case math, text, any }
    public var mode: Mode          // Math only / Text only / neither chip
    public var autoExpand: Bool    // hsnips A
    public var wholeWord: Bool     // hsnips w (else i)
    public var lineStart: Bool     // hsnips b
    public var isRegex: Bool       // backtick trigger
}
```

Defaults: `mode = .math`, `autoExpand = true`, everything else false. These
reproduce today's `UserSnippet` defaults exactly.

`UserSnippet` becomes:

```swift
public struct UserSnippet: Codable, Equatable {
    public let id: String
    public var trigger: String
    public var replacement: String
    public var options: SnippetOptions
    public var enabled: Bool
    /// Non-nil when this row overrides a built-in; the built-in's disable key.
    public var overridesBuiltinKey: String?
}
```

### Migration

`init(from decoder:)` decodes `options` when present. When absent, it builds
one from the legacy keys: `autoExpand` carries over, `mathOnly == true` maps to
`.math`, and `mathOnly == false` maps to `.any` (not `.text` — the old switch
meant "anywhere", not "prose only"). `overridesBuiltinKey` defaults to nil.

Migration is read-time and lossless; the next write persists the new shape.
No migration pass over UserDefaults, no version counter.

## Wire format

[SnippetComposer](../../../mac/ChalkKit/Sources/ChalkKit/SnippetComposer.swift)
keeps its structure — bundled defaults, then a generated block — and gains:

| Option | Emitted |
| --- | --- |
| `mode == .math` | `context math(context)` before the header |
| `mode == .text` | `context !math(context)` before the header |
| `mode == .any` | no context line |
| `autoExpand` | `A` in the flag group |
| `wholeWord` | `w` in the flag group (otherwise `i`, today's behavior) |
| `lineStart` | `b` in the flag group |
| `isRegex` | header trigger wrapped in backticks |

`priority 10` is still emitted per snippet — the parser resets priority after
each one, so user shortcuts need it repeated to shadow built-ins.

Every `overridesBuiltinKey` on an enabled user snippet is added to the
`# chalk-disable:` key set, alongside the keys from explicit off-switches.
This makes an override unambiguous even when the fork changes the trigger.

`!math(context)` needs no editor-core work — the plugin already handles it
([hsnips-plugin.ts:225](../../../packages/editor-core/src/editor/hsnips-plugin.ts#L225)).

### Validation

hsnips has no escaping, so validation rejects what the format cannot carry,
and nothing more:

- Backticks in a trigger: rejected in all modes. They delimit the regex form.
- Whitespace in a trigger: rejected for literal triggers, allowed for regex
  ones — the header pattern `` `([^`]+)` `` tolerates spaces.
- Empty trigger or replacement: rejected (unchanged).
- `endsnippet` at the start of a replacement line: rejected (unchanged).
- `` `` `` in a replacement: rejected (unchanged) — it opens a JS block.
- Regex mode: the pattern must compile via `NSRegularExpression` before save.

Swift's ICU dialect and the editor's JS dialect are not identical, so the
compile check is a first filter, not a guarantee. The parser must therefore
also survive a pattern that only JS rejects — see below.

## editor-core changes

### Regex capture substitution

[processBody](../../../packages/editor-core/src/editor/hsnips-plugin.ts#L354)
receives regex groups and discards them (`void groups`). That is why the
bundled asset's regex snippets are degraded today: 47 of its snippets use a
backtick trigger, and roughly 25 reference `` `rv = m[1]` `` in their body,
which `parseBody` strips. Typing `xbar` inserts `\bar{}` rather than
`\bar{x}`. No test covers this.

Two changes fix it and make user regex snippets worth having:

1. **`processBody` substitutes `#1`…`#9`** from `groups` when the snippet
   matched via regex. `#N` is the LaTeX argument idiom, so it reads correctly
   to this audience, and it leaves `$1`/`${1:default}`/`$0` free to keep
   meaning tabstops. Out-of-range references (`#3` with two groups) substitute
   empty. A literal `#` not followed by a digit is untouched. Non-regex
   snippets leave `#N` alone.
2. **`parseBody` rewrites `` `rv = m[N]` `` and `` `rv = m[N].trim()` ``
   to `#N`** instead of stripping them. Narrow pattern match, no eval.
   Everything else inside `` `` `` keeps being stripped.

   Trimming stays out of band rather than becoming in-body syntax: `HSnippet`
   gains `trimmedCaptures: Set<number>`, filled by `parseBody` from the
   `.trim()` occurrences, and `processBody` trims those indices when it
   substitutes. If index N appears both raw and trimmed in one body, trimmed
   wins for every `#N` in it — no such body exists in the asset, and an
   in-band marker would risk colliding with real LaTeX (`~`, `!`, and `t`
   after a digit are all plausible snippet text).

This keeps `assets/latex.hsnips` valid upstream hsnips — it stays consumable
by HyperSnips, which matters because it is the single source of truth copied
verbatim into both hosts.

### Parser resilience

[hsnips-parser.ts:164](../../../packages/editor-core/src/editor/hsnips-parser.ts#L164)
calls `new RegExp(pat, 'm')` unguarded. One bad pattern throws out of
`parseHSnips` and destroys the whole snippet set. Wrap it, skip the snippet,
`console.warn` once. Required now that users can author patterns.

### Catalog

`BuiltinSnippet` (already in ChalkKit, next to the model) gains
`replacement: String` and `options: SnippetOptions`, replacing its current
`autoExpand`/`mathOnly` booleans. `HSnipsCatalog.scan` must capture snippet
bodies instead of skipping to `endsnippet`, apply the same inline-JS stripping
and `rv = m[N]` rewriting the parser does, and read `w`/`b`/`i` flags and
`!math(context)` contexts.

The known blind spot stays documented: an `endsnippet` line inside a multi-line
JS block would end the body scan early. Absent from the bundled file; the
existing catalog tests run against the real asset and would catch a regression.

Bodies display post-strip — what actually gets inserted, not what the file
says. With `rv = m[N]` rewriting in place, that display is now the useful form
(`\bar{#1}`), so a fork inherits working text.

## UI

Replaces `ShortcutsSettingsViewController`'s two-list layout and retires
`SnippetEditorViewController` (the pushed form has no remaining callers).

**Structure.** One `UITableView`, two sections — "Your Shortcuts", "Built-in"
— under a fixed header row labelling the three columns. Search stays in the
table header and filters both sections.

**Columns.** A custom cell lays out a trigger `UITextField`, a replacement
`UITextView`, and a chip button. Widths come from multipliers off the cell's
content layout guide so every row aligns. All `ChalkMetrics.s`-scaled;
Catalyst's 0.77× render means fixed point sizes will not survive.

**Inline editing.** Focusing the replacement grows the row via
`performBatchUpdates` on content-height change; blur collapses it to one line.
Edits commit on end-editing, then debounce into `SnippetLibrary.invalidate()`
and the existing `onSnippetsChange` push, so hsnips is not recomposed per
keystroke.

**As built: rows never collapse.** The replacement is a permanently
non-scrolling `UITextView` whose intrinsic height drives the row, focused or
not, so a three-line snippet is a three-line row at rest. Growing on focus and
collapsing on blur would mean two heights per row and a `performBatchUpdates`
on every focus change, and the table already reloads on edits — every tap into
a row would reflow the rows below it. A stable height is worth more here than
a compact list, and it makes the replacement column readable without focusing
anything.

**As built: the debounce coalesces the push, not the write.** `invalidate()`
is *not* debounced — it runs synchronously on every mutation, so nothing that
asks `SnippetLibrary` for content in between (a tab opening, say) can be
handed the stale cache. The store write is synchronous too. Only
`onSnippetsChange` — recomposing all 263 snippets and pushing the result
across the WKWebView bridge — is coalesced, on a 250 ms trailing timer, which
is what `keepsMenuPresented` needs: several chip toggles in a couple of
seconds otherwise pay for the whole set each time.
`ShortcutsSettingsViewController` flushes any pending push in
`viewWillDisappear` and in `deinit`, so leaving the screen cannot outrun it.

**Chips.** The cell renders active options as compact chips (`Math`, `Auto`,
`Regex`, `Whole word`, `Line start`). Tapping opens a `UIMenu` of labelled
toggles with `keepsMenuPresented = true`, so several can be set in one pass.
Math only and Text only are mutually exclusive; turning one on clears the
other, and both off means `.any`.

**As built: no Whole word on a regex trigger.** `findMatch` branches on
`snippet.trigger` vs `snippet.regexp`, and the regex branch reads only
`beginofline` — never `inword` or `wordboundary`. So `w` is inert on a regex
snippet. Settings drops both the toggle and the chip when `isRegex` is set
(`SnippetOptions.wholeWordApplies`) rather than offer a control that does
nothing. The composer still emits the flag, and the engine's matching
semantics are unchanged; making `w` mean something for regex triggers is a
separate decision.

**Adding.** A trailing blank row in section 0, spreadsheet-style. Typing into
it creates the snippet. It hides while a search filter is active, as the
current Add row does.

**Built-in rows.** Rendered from `BuiltinSnippet` unless a user snippet's
`overridesBuiltinKey` matches, in which case the row renders the user's data
and shows a `Modified` marker. Editing any cell of a built-in row forks it in
place — same position, no jumping — creating a `UserSnippet` seeded from the
built-in with `overridesBuiltinKey` set. Swipe gives Reset (delete the fork).
The row keeps its enable checkbox in both states.

**Deletion.** Swipe deletes user rows, as today.

Adding the cell class and removing `SnippetEditorViewController.swift` both
need `cd mac && xcodegen generate` — the project file is generated from
folder groups in [project.yml](../../../mac/project.yml).

## Out of scope

- VS Code. That host reads real `.hsnips` files from disk
  ([hsnips-paths.ts](../../../vscode/src/extension/hsnips-paths.ts)); this is a
  Settings-sheet feature.
- Import/export of snippet sets.
- Snippet priority as a user-facing control. All user snippets stay at 10.
- Rich preview of what a replacement renders to.

## Testing

**ChalkKit** (`pnpm test:swift`, no simulator):

- `SnippetOptions` round-trips; legacy `UserSnippet` JSON migrates, including
  `mathOnly: false → .any`.
- Composer output per option combination: context line, flag group, backtick
  trigger, priority placement.
- `overridesBuiltinKey` lands in the `# chalk-disable:` line; regex keys with
  spaces are backtick-quoted.
- Validation: backtick trigger, whitespace in a literal trigger, whitespace
  allowed in a regex trigger, uncompilable pattern.
- `HSnipsCatalog` extracts bodies, `w`/`b` flags, and `!math(context)` from
  the real bundled asset.

**editor-core** (vitest):

- `#1`…`#9` substitute from captures; out-of-range yields empty; `#` before a
  non-digit is literal; non-regex snippets pass `#N` through.
- `` `rv = m[1]` `` and the `.trim()` variant rewrite correctly; other JS
  blocks still strip.
- A regression test for a real built-in: `xbar` produces `\bar{x}`.
- An invalid pattern is skipped and the rest of the file still parses.
- Parity: a literal copy of composer output parses back to the intended flags,
  following `hsnips-disable.test.ts`.

**Manual**, on both idioms: row growth and collapse, chip menu multi-select,
fork-in-place and reset, and that an edit reaches an open editor.

## Risks

- Inline `UITextView` growth inside `UITableView` under Catalyst is the
  fiddliest part; row-height math interacts with `ChalkMetrics.s` scaling.
  Build it as an isolated cell class with its own height calculation.
- `parseBody` rewriting is a change to shared parsing used by both hosts. The
  pattern match must be narrow enough that no existing body changes meaning.
- Forking depends on catalog body extraction being faithful. The catalog
  mirrors the parser rather than reusing it (Swift/TS split), so the tests
  against the real asset are the guard.
