# Keeping the chrome correct

How to run, read, and extend the chrome-invariant suite.

This is the operator's guide. The **rules themselves** live in
[ui-invariants.md](ui-invariants.md), which is generated from the Swift catalogue
and also documents exactly which rules are asserted where.

## Why it exists

On 2026-08-19 six chrome-geometry bugs were found by eye in one morning. Every
wrong version built cleanly and passed all 313 Swift tests. Fixing one in a
windowed Mac window still left the same bug live in full screen, because full
screen is a separate code path.

The suite exists so that class of bug fails a test instead. On its first honest
run it found two live bugs nobody had seen, and caught a third the moment a fix
introduced it.

## Run it

| Command | Covers | Time |
| --- | --- | --- |
| `xcodebuild test -project mac/Chalk.xcodeproj -scheme Chalk -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:ChalkTests/ChromeInvariantMatrixTests -derivedDataPath mac/build/dd CODE_SIGNING_ALLOWED=NO` | all 32 cells | seconds after build |
| `node scripts/generate-ui-invariants.mjs --check` | the docs match the catalogue | instant |
| `./scripts/check.sh` | both of the above, plus everything else | minutes |

`check.sh` runs them as the `ui-invariants` and `invariants-doc` steps.

**Never pipe `xcodebuild` through `head`.** Closing the pipe early sends SIGPIPE
and the build stops without saying so, which reads exactly like a failure.

## Read a failure

Every failure names the state and the rule, then prints the geometry:

```
fullscreen-sidebar-nooutline-normal-light: bandSpansFullWidth
  The tab band is one strip across the whole window. A band that stops at the
  sidebar divider reads as a bar that gave up halfway...
  root=(0, 0, 1728x1080) band=(473, 0, 1255x36) paint=(561, 0, 1167x36)
  hole=nil panel=Optional((13, 13, 547x1054)) chips=(574, -24, 279x60) resting=63
```

Read it in this order:

1. **The state id** tells you where to reproduce it: window mode, sidebar,
   outline panel, editing mode, appearance. `CHALK_AUDIT_STATE=sidebar-deep` plus the
   right window gets you close by hand.
2. **The rule name** is the vocabulary. Say `bandSpansFullWidth` rather than
   describing the picture.
3. **The rects** are the evidence. Above: the band starts at x=473 in a 1728pt
   window, and the chips are at y=-24 so their top 24pt is off-window.

### The other failure mode

```
8 of 32 state(s) assert NOTHING falsifiable (a blind spot, not a pass): ...-zen-...
```

This is the coverage guard. A state where every applicable rule reduces to
something always true is a blind spot, and the suite refuses to call that a
pass. Zen cells are the usual suspects: they hide the band and close the
Library, so many rules have no geometry to test. The guard has been green since
2026-08-23 (see `docs/known-failing-tests.md`).

If it goes red, a change has blinded states that used to be covered. Add
geometry for the rules to bite on; never loosen the guard.

## Add an invariant

This is the loop the system is built around: something wrong is spotted by eye
once, and becomes a rule that can never come back.

1. **Name the relationship**, not the symptom. "the bar should go behind the
   sidebar" becomes `libraryIsNeverPaintedOver`.
2. **Add it** to `ChromeInvariant.catalogue` in
   `mac/ChalkKit/Sources/ChalkKit/ChromeInvariants.swift`:

```swift
ChromeInvariant(
    name: "libraryIsNeverPaintedOver",
    rationale: "The Library panel keeps its own surface. The band runs behind it, "
             + "which means the panel is cut out of the paint rather than drawn over.",
    appliesTo: hasLibrary,          // omit if it applies everywhere
    holds: { layout in
        guard let panel = layout.libraryPanel else { return true }
        return !layout.paintCovers(panel)
    }),
```

3. **Write the `rationale` as a sentence a person would say.** It is rendered
   into `ui-invariants.md` and is what makes the name usable in conversation.
4. **Prove it can fail.** Reintroduce the bug (or stub the predicate) and watch
   it go red on the right states. A rule nobody has seen fail is not evidence.
5. **Regenerate the docs:** `node scripts/generate-ui-invariants.mjs`.
6. Run the matrix on Mac Catalyst.

### Rules must be relationships

`band.minX == root.minX`, never `band.minX == 0`. Mac Catalyst scales the UIKit
idiom to 77% and aligns to the pixel grid, and window sizes differ per cell, so
an absolute assertion is either wrong somewhere or accidentally true.

## Add a state, or a new rect

- **A state dimension** goes in `UIState`
  (`mac/ChalkKit/Sources/ChalkKit/UIState.swift`). Adding a case doubles the
  matrix; the invariant layer absorbs that for free because it does not render.
  Then teach `ChromeInvariantMatrixTests.root(in:)` how to configure it.
- **A new piece of chrome** goes in `ChromeLayout`
  (`mac/ChalkKit/Sources/ChalkKit/ChromeLayout.swift`), and
  `RootSplitViewController.chromeLayout(for:)` must read it from a **live view**
  and convert it into the root's coordinate space.

## Traps, all of them paid for

**Report live views, never constants.** If `chromeLayout` computed a rect from
`ChalkMetrics` instead of reading the view, every rule over it would be a
tautology that passes while the screen is wrong.

**Window-host the root.** UIKit delivers the sidebar carve through the
secondary column's safe area, and safe areas only resolve inside a real window.
An unhosted root reports the chips at the window's raw leading edge no matter
what the sidebar is doing — the suite passes while blind.

**Reset persisted preferences per state.** `Preferences.editingMode` survives
between states, and `applyZenChrome` early-returns when it already believes it is
in zen. That made half the zen cells silently not in zen chrome, which showed up
as a light/dark coverage difference — appearance cannot change geometry, so that
asymmetry was the tell.

**Count falsifiable assertions, not applicable ones.** `chromeStaysInsideTheWindow`
applied everywhere, but against all-zero rects it reduces to
`root.contains(.zero)`, which is always true. In an earlier version of the
matrix, twenty of thirty-two states looked covered and asserted nothing.

**`band` and `bandPaint` are different things.** Three of the six original bugs
had a correct band frame and a wrong painted region. Never collapse them.

**One source of truth for a shared number.** Three sites computed the Mac band
height; flooring two of them left the third disagreeing, and the editor's resting
line stayed measured against a height that no longer existed.
That arithmetic is now the one pure `BandLayout.resolve`, applied by `RootSplitViewController.applyBandLayout()`.

## What this does NOT cover

Be honest about the edges; a system trusted past its limits is worse than none.

- **The AppKit glue.** `ChalkAppKitGlue` is a runtime-loaded bundle no test target
  links, so the Mac *windowed* tab strip cannot be asserted here. Its geometry
  lives in `ChalkKit.TitlebarBandGeometry` and is unit-tested separately, and
  since 2026-09-10 so does the rest of its vocabulary: `TabStripBridge` (the
  bridge's notification names and userInfo keys), `TabStripPolicy`,
  `TabStripMetrics`, `ChalkTheme` and `WindowRouting` are compiled into the
  glue rather than mirrored into it, so what the AppKit strip runs is what
  ChalkKit's tests exercise.
- **Anything below the chrome.** Math, tables, code blocks and the writing
  surface are covered by the jsdom suite in `packages/editor-core/test` and by
  the browser harnesses, which all live in one tree beside the snapshots:
  `Tests/browser` (`pnpm test:browser`), `Tests/fixtures` (`pnpm test:caret`),
  `Tests/matrix` (`pnpm test:matrix:geo`) and the 16 web snapshots in
  `Tests/__Snapshots__`. They share one engine-lane bootstrap
  (`Tests/runner/lib/browser.mjs`, selected by `CHALK_BROWSER`)
  and one tagged accepted-failure format (`Tests/runner/lib/known-failures.mjs`).
  `check.sh` runs them as the `browser-tests`, `caret-fixtures`,
  `geometric-matrix` and `snapshots` steps.
- **Rendering faults.** Frames cannot express a wrong fill, a missing mask, or a
  square corner where the panel curves. Three of the six original bugs were of
  that kind. The contact-sheet layer in the spec is the answer and is not built:
  `docs/specs/2026-08-19-ui-correctness-system-design.md`.
- **The chrome reserve.** Nothing checks what actually reserves space at rest or
  in zen, because `ChromeLayout` has no field distinguishing "the reserve" from
  "the UIKit band frame". The reserving chrome is an AppKit titlebar the layout
  cannot see.

## File map

| File | Role |
| --- | --- |
| `mac/ChalkKit/Sources/ChalkKit/UIState.swift` | the 32-cell matrix and its ids |
| `mac/ChalkKit/Sources/ChalkKit/ChromeLayout.swift` | the geometry, as a value |
| `mac/ChalkKit/Sources/ChalkKit/ChromeInvariants.swift` | the rules |
| `mac/ChalkTests/ChromeInvariantMatrixTests.swift` | drives the matrix, asserts the rules |
| `mac/Chalk/App/RootSplitViewController.swift` | `chromeLayout(for:)`, in its `#if DEBUG` block |
| `scripts/generate-ui-invariants.mjs` | renders the catalogue; `--check` fails on drift |
