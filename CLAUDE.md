# Chalk (monorepo)

Live-preview editor for `.tex`/`.md` with KaTeX math and hsnips snippets.
Native Mac app in [mac/](mac/) (AppKit, in [mac/Chalk/](mac/Chalk/)),
VS Code extension in [vscode/](vscode/), shared engine in
[packages/editor-core/](packages/editor-core/). The Mac shell was ported from
Mac Catalyst to AppKit in October 2026
([docs/specs/2026-10-15-appkit-shell-rewrite-plan.md](docs/specs/2026-10-15-appkit-shell-rewrite-plan.md));
anything UIKit-free lives in ChalkKit, and the shell's spec chrome tokens are
`ChalkMetrics` in Mac points.

## Architecture: one engine, two hosts, two seams

- **`HostPort`** ([packages/editor-core/src/host-port.ts](packages/editor-core/src/host-port.ts)):
  frozen 9-message protocol. Host→editor: `init`, `update`, `theme-colors`,
  `heading-colors`, `editor-config`, `hsnips`. Editor→host: `ready`, `edit`,
  `open-external`. Entry point `mountEditor` ([mount.ts](packages/editor-core/src/mount.ts)).
  The native transport additionally carries transport-internal messages
  (`resolve-asset` request/reply, `scroll` telemetry, `outline` pushes for the
  persistent panel, `command` save/toggle-outline/toggle-outline-panel) and the
  `window.__chalkEditor` bridge (clipboard, outline access, and
  `setOutlineSubscription`, which turns the `outline` pushes on and off),
  mirrored in [WebEditorSurface.swift](mac/Chalk/Editor/WebEditorSurface.swift).
  - Native transport: `WKScriptMessageHandler` / `evaluateJavaScript`
    ([web/src/native-host.ts](web/src/native-host.ts) ↔ [mac/Chalk/Editor/WebEditorSurface.swift](mac/Chalk/Editor/WebEditorSurface.swift)).
    Swift `Codable` mirrors: [mac/ChalkKit/Sources/ChalkKit/HostProtocol.swift](mac/ChalkKit/Sources/ChalkKit/HostProtocol.swift).
  - VS Code transport: webview postMessage ([vscode/src/webview-entry.ts](vscode/src/webview-entry.ts)).
- **`EditorSurface`** ([mac/Chalk/Editor/EditorSurface.swift](mac/Chalk/Editor/EditorSurface.swift)):
  the native shell's swap seam so a TextKit 2 surface could one day replace
  the webview without touching tabs/documents.

On the Mac, edits buffer host-side and flush on save (no autosave); VS Code
applies each edit to the `TextDocument` as you type and saves through VS
Code. Host→editor `update`s
apply as minimal diffs. See [packages/editor-core/CLAUDE.md](packages/editor-core/CLAUDE.md)
for engine guardrails before touching editor code.

## Build systems (two)

| Part | Tool | Commands |
|---|---|---|
| mac/ | XcodeGen + xcodebuild | `cd mac && xcodegen generate`, then scheme `Chalk` with destination `platform=macOS`; `mac/Chalk.xcodeproj` + `Info.plist` are generated — edit [mac/project.yml](mac/project.yml) |
| packages/, vscode/, web/ | one pnpm workspace, one lockfile | `pnpm install`, `pnpm test`, `pnpm typecheck` (includes `web/`), `pnpm -C vscode build`, `pnpm web:build` |

`Chalk` is the only scheme; it builds the app and tests the `ChalkTests`
bundle. Local builds are unsigned and then ad-hoc signed
([scripts/install-mac.sh](scripts/install-mac.sh)); the project sets no
development team.
[scripts/release-mac.sh](scripts/release-mac.sh) is the signed release path
([docs/release-steps.md](docs/release-steps.md)). Rerun `xcodegen generate`
after adding a Swift file: sources are globbed at generation time.

`web/` depends on `@chalk/editor-core` via `workspace:*`, and esbuild bundles
the package's TypeScript source through its `exports`. The Xcode pre-build
phase runs `node web/build.mjs` directly (no pnpm needed there), so it only
requires `pnpm install` to have run at the repo root; Release fails and Debug
warns when node or `node_modules` is missing.

## Tests: one tree

Every harness that drives a real browser lives under [Tests/](Tests/):
`Tests/browser` (the scenario harness, `pnpm test:browser`), `Tests/fixtures`
(the caret/mouse fixture files, `pnpm test:caret`), `Tests/matrix` (the
caret/reveal discovery matrix, `pnpm test:matrix:geo`), `Tests/__Snapshots__`
(the 16-case layout matrix of the editor surface) and `Tests/runner` (the
runners plus the shared `lib/browser.mjs` engine-lane bootstrap, chromium or
webkit via `CHALK_BROWSER`, and `lib/known-failures.mjs` tagged
accepted-failure format). jsdom unit tests stay beside their package, in
`packages/editor-core/test/`; Swift tests stay in `mac/`.

[scripts/check.sh](scripts/check.sh) runs the lot. Its `--list` names every
step: build-web, typecheck, xcodegen, build-mac, invariants-doc,
engine-tests, chalkkit-tests, caret-fixtures, browser-tests,
geometric-matrix, snapshots, pref-guard, ui-invariants, mac-tests, bench.
`--fast` skips the three Xcode test steps and the benchmarks.
Debug builds, and so the ChalkTests host, use the bundle ID
`com.huleux.chalk.debug`: tests write `UserDefaults.standard`, and must never
share a domain with the installed Release app (`com.huleux.chalk`). It parses each runner's output with a fixed extractor, so a
runner that changes its failure lines must change the extractor with it.

ChalkKit ([mac/ChalkKit/](mac/ChalkKit/)) is pure Foundation — no UIKit —
so `swift test` works from the command line without Xcode's test runner
(`pnpm test:swift`); it carries the Swift↔TS protocol-parity round-trips.

## Guardrails

- Don't break the `HostPort` protocol; both hosts and the Swift mirror types
  must change together if it ever grows.
- editor-core stays host-agnostic: no UIKit/VS Code/Tauri assumptions, no CSS
  beyond its own stylesheets. The `--vscode-*` CSS variables in its theme all
  have hardcoded fallbacks — leave them. Keep its touch handling: VS Code runs
  on touchscreen laptops.
- **Chrome geometry is asserted, not eyeballed.** `ChromeInvariantMatrixTests`
  drives a 96-cell state matrix (window mode x sidebar x trailing slot
  (closed, outline, PDF) x editing mode x split x appearance) and checks named rules over the chrome's real
  laid-out frames. Before changing the band, the Library panel,
  the tab strip or the editor's resting offset, read
  [docs/ui-correctness.md](docs/ui-correctness.md) — it lists the traps that
  make this class of test silently vacuous (unhosted roots, persisted
  preferences, counting applicable instead of falsifiable assertions). The rules
  themselves are generated into [docs/ui-invariants.md](docs/ui-invariants.md);
  `scripts/check.sh` fails if that file drifts from the Swift catalogue.

## Comments

Written for the next reader, usually an agent that reads every line.

- Keep the why: invariants, traps, "don't do X because Y", non-obvious
  platform behaviour, ordering constraints. One to three lines.
- An incident is one clause of cause plus a pointer to its note in
  `docs/issues/`. The story (dates, who asked, how it was debugged) goes in
  that note or the commit message, never in code.
- No history: nothing about removed code or what something used to do.
- Don't restate the code, and don't describe another file's internals; name
  the symbol instead.
- A comment that disagrees with the code is a bug: fix or delete it in the
  same change.
