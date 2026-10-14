# A system for keeping Chalk's UI correct

Design, 2026-08-19.

## The problem, stated from evidence

On 2026-08-19 six chrome bugs were found and fixed across Mac and iPad. Every wrong version **built cleanly and passed the entire test suite**. Every one was caught by the owner looking at a screenshot.

The bugs:

| # | Bug | Nature |
| --- | --- | --- |
| 1 | Band stopped at the sidebar divider (Mac) | geometry |
| 2 | Band stopped at the sidebar divider (iPad) | geometry |
| 3 | Full-width band covered the Library panel | geometry |
| 4 | Square notch at the panel's rounded corner | rendering |
| 5 | Dark line across the sidebar under the band | rendering |
| 6 | Doubled dark layer hid a working mask (iPad) | rendering |

Three properties of this class of defect:

- **Trivial to see, hard to describe.** "The black bar should go all the way underneath it" took three attempts to interpret correctly, and one attempt made things worse.
- **Invisible to the existing suite.** 313 Swift tests and 764 engine tests all passed through all six.
- **Recurring.** `docs/issues/2026-08-18-mac-tabs-vanish-when-the-library-is-open.md` records the owner's own words: "We solved this many times but the bug keeps coming back."

The state space is large: platform x window mode x sidebar x editing mode x appearance.

## What is actually testable, measured

An earlier claim in this session — that Mac chrome could not be tested — was **wrong**, and the correction shapes the design.

`ChalkTests` had never been compiled for Mac Catalyst. Two iPad-only references were the only obstacle:

- `HeaderBandTests` -> `ChalkMetrics.editorSidePadding`
- `ShellGestureInstallTests` -> `RootSplitViewController.sidebarViewForGestures`

With both guarded and a `ChalkMac` scheme that omits `ChalkUITests` (which cannot compile for macOS, `XCUIDevice.press(.home)`), the suite runs on Catalyst: **293 tests, 274 passing, 19 failures**, in about 10 seconds.

So the Mac chrome IS reachable from a test, on the real platform, with real laid-out frames. The genuinely unreachable part is only `ChalkAppKitGlue`, a runtime-loaded bundle no test target links.

The 19 failures are unexamined; most look like iPad numbers meeting Catalyst's 1/0.77 render scale, but `EditingModeTests` expecting a zen band height of 57.14 and getting 0.0 may be a real Mac bug. They need triage and are out of scope for this design.

## Architecture: three layers

### Layer 1 — Chrome invariants (the workhorse)

XCTest in `ChalkTests`, run on **both** platforms. The app produces a named rect set per state; invariants are pure predicates over it.

```swift
// ChalkKit: pure, no UIKit
struct ChromeLayout {
    let state: UIState
    let root: CGRect
    let band: CGRect           // the tab band's frame
    let bandPaint: CGRect      // its OPAQUE region
    let libraryPanel: CGRect?  // nil when hidden
    let tabStrip: CGRect       // the chips
    let footerPill: CGRect?
    let editorRestingTop: CGFloat
}
```

`band` and `bandPaint` are separate on purpose. Bugs 4, 5 and 6 all had a correct frame and an incorrect painted region; a single rect makes that class invisible.

Invariants are named predicates:

```swift
Invariant("bandSpansFullWidth")        { $0.band.minX == $0.root.minX && $0.band.maxX == $0.root.maxX }
Invariant("libraryIsNeverPaintedOver") { !$0.bandPaint.intersects($0.libraryPanel ?? .null) }
Invariant("chipsStartAtTheEditorColumn") { ... }
Invariant("restingLineSitsOneLineBelowTheBand") { ... }
```

Cost: about 10 seconds for the whole matrix, no rendering.

### Layer 2 — Glue geometry

Pure functions in ChalkKit for decisions inside `ChalkAppKitGlue`. `TitlebarBandGeometry` is the first. This layer exists **only** because that bundle is unreachable; it is not the general pattern.

**Discipline: production consumes it, never mirrors it.** The moment the pure function becomes a copy of what the draw call does, the tests are fiction. Bug 5 was exactly this: the model said "nothing paints below the band" and the drawing did not honour it, because the drawing did not call the model for its clip.

### Layer 3 — Contact sheet

The real app renders every cell on both platforms into one labelled grid. Catches what frames cannot express: fills, masks, corner curves, layer stacking.

## The state matrix

Declared once in ChalkKit as pure data, consumed by all three layers and by the owner.

```swift
struct UIState {              // id: "mac-windowed-sidebar-zen-dark"
    let platform: Platform    // mac | ipad
    let window: WindowMode    // windowed | fullscreen   (iPad: pane | full)
    let sidebar: SidebarState // shown | hidden
    let mode: EditingMode     // normal | zen
    let appearance: Appearance// light | dark
}
```

32 cells. `EditingMode` also has `typewriter` and `focus`; they change the writing surface rather than the chrome and are deferred until the scope widens past chrome.

Content is **held constant** across the 32 chrome cells (one document, three tabs). If content varies with chrome, a diff cannot say which one moved.

The 24 existing ad-hoc audit states (`tabs12`, `longtabs`, `sidebar-deep`) stay as extra contact-sheet cells. They stress the strip in ways a dimensional cell does not, but they are held out of the cross-product so they do not multiply it.

### The cost asymmetry drives the tiering

Layer 1 does not render, so it covers all 32 cells in seconds. Only Layer 3 is expensive.

| Tier | Cells | Cost | When |
| --- | --- | --- | --- |
| invariants | all 32 | ~10s | every build |
| narrow render | 6 | ~40s | any change touching chrome, before the owner sees anything |
| full render | 32 + scenarios | ~4min | before a change lands, or on demand |

## Never trust a capture

Three times on 2026-08-19 a capture returned a plausible but wrong image — twice a stale window, once a 3388x76 titlebar — and each produced a wrong conclusion, including "my own fix is broken" when it was not.

Every capture asserts, and any failure aborts rather than returning an image:

1. **Build stamp** — the app logs its build SHA; the harness compares it to the binary it just built.
2. **Window identity** — the captured window's size matches the state's expected size.
3. **Glue loaded** — on Mac, `isAppKitGlueAvailable` must be true. Otherwise the app renders the UIKit fallback, which looks plausible and is a different UI.
4. **Settled** — wait for a `UI_READY <state-id>` log line, never a fixed sleep.

## Baselines and approval

Baselines: `Tests/__Snapshots__/chrome/<cell-id>.png`.

A run diffs per cell and writes a **review sheet**: only changed cells, before and after, side by side, labelled. That is the artifact handed to the owner, not a wall of 32 images.

Approval is a separate explicit command, `scripts/ui-approve.sh <cell-id>`, which appends to a changelog with a reason. **An agent may never run it.** `scripts/guard.sh` already forbids modifying `Tests/__Snapshots__/`; this extends that protection to the chrome set.

## The reporting loop

1. The owner circles a cell on the contact sheet and writes a sentence.
2. The relationship is named (`bandRunsBehindLibrary`) and added as a predicate.
3. It runs against all 32 cells immediately, which routinely reveals the same fault in states nobody looked at.
4. It is permanent.

Step 3 is where this compounds. Bug 1 was found on Mac; the same predicate would have flagged bug 2 on iPad in the same second, rather than two hours later.

The generated catalogue, `docs/ui-invariants.md`, lists every rule in plain English. It is the shared vocabulary that answers "hard to explain": once `libraryIsNeverPaintedOver` exists, the owner can name it instead of describing the picture.

## Coverage check against the six bugs

| Bug | Caught by |
| --- | --- |
| 1, 2 band stops at divider | Layer 1 — `bandSpansFullWidth` |
| 3 band covers the Library | Layer 1 — `libraryIsNeverPaintedOver` |
| 4 corner notch | Layer 3 — geometry was correct |
| 5 dark line | Layer 3 — frame correct, painted region wrong |
| 6 doubled dark layer | Layer 3 — two correct layers, wrong together |

Half are downstream of correct geometry, so Layer 3 is not optional. But Layer 1 is where explanations come from: it fails with a relationship name, not a pixel count.

## Build order

| Stage | Deliverable | Rationale |
| --- | --- | --- |
| 1 | `ChromeLayout` + the 6 invariants from today, both platforms | Catches 3 of 6 bugs, no rendering, smallest piece that pays |
| 2 | `UIState` matrix; invariants iterate all 32 cells | Turns 6 checks into 192 at no extra cost |
| 3 | Contact sheet renderer + the 4 capture assertions | Catches the rendering-fault half |
| 4 | Baselines, diff, review sheet, approval command | Makes it a ratchet rather than a report |
| 5 | `guard.sh` coverage + generated `docs/ui-invariants.md` | Locks it, and makes the vocabulary readable |

Stage 1 alone would have caught bugs 1, 2 and 3 in ten seconds, before any screenshot was taken.

## Explicit non-goals

- **Not a general visual regression system.** Chrome geometry first; the writing surface already has 32 web snapshots and has not regressed.
- **Not a replacement for the owner's eye.** It is a ratchet: whatever the eye catches once, the system holds forever.
- **Not CI-gated initially.** Local tiers first. A green local run is worth more than a red pipeline nobody reads.
- **Not a fix for the 19 Catalyst failures.** Those need triage on their own terms.
