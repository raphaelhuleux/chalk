# Motion

The contract for every chrome transition: what moves, what never moves, on what clock, and what a test asserts.
Written 2026-08-23 (the polish night). Companion to [ui-correctness.md](ui-correctness.md); the transition matrix and the contract tests in `ChalkTests` enforce the testable half.

## Principles

- The text surface never reflows mid-motion and never shows stale tiles. The webview's bounds change exactly once per transition, after the visible motion, under an opaque cover that outlives the async repaint (the sidebar settle is the proven pattern).
- One transition, one clock. Every element that moves in the same transition shares one duration token and one curve. The AppKit strip follows a duration carried in the notification payload; it never picks its own.
- Motion explains geometry: panels slide from their resting edge; nothing teleports; a canceled transition rewinds cleanly (`.beginFromCurrentState`, idempotent settle).
- Reduce Motion swaps slides for instant placement but keeps every correctness cover (a mismatch flash is a bug, not a motion).
- At rest, nothing animates.

## Tokens

| Token | Value | Curve | Used by |
| --- | --- | --- | --- |
| `motionTab` | 0.10 | ease-out | tab hover fills, dirty-dot/close swap |
| `motionFast` | 0.15 | ease-out | tab close, tab switch cross-fade, the active underline's slide, band fade-in after fullscreen, cover fades |
| `motionStandard` | 0.20 | ease-in-out | zen chrome fade, appearance cross-dissolve, sheets |
| `motionSidebar` | 0.22 | ease-out | sidebar slide: column, editor content translation, AppKit strip, chip inset (new token; replaces the hardcoded 0.13/0.18 pair) |
| auto-hide | 0.22 | ease-out | band/pill auto-hide (existing; aligns with `motionSidebar`) |

No springs on anything that moves the webview or its cover; springs overshoot and the cover cannot overshoot a remote layer.

## Transitions

### Sidebar show/hide (both platforms, one code path)

Moves: the Library column (translation), the editor content (translation by the centered-column delta), the tab chips' leading inset (same clock, target posted at slide START in the payload).
Never moves: the webview's bounds (frozen width until settle), the band frame, the pill.
Settle: display mode snapped without animation up front; after the slide, snapshot cover -> single reflow -> fade after two in-page rAFs; release armed BEFORE any async step, so a missing snapshot degrades to a covered reflow, never a stuck width.
Test: `SidebarSlideContractTests` (bounds frozen, one reflow, release under a dead snapshotter, rapid re-toggle cancels), transition matrix equality with the fresh state.

Implemented 2026-08-24 (C1); what building it taught:

- The settle is `WebPaintGate` (mac/Chalk/App/WebPaintGate.swift). "Release armed before any async step" became TWO clocks funneling into two idempotent steps: a snapshot backstop (0.25 s) that runs the covered reflow without the bitmap, and a paint backstop (0.6 s) that fades a cover whose in-page rAF gate never answers. One armed release was not enough — the snapshot and the paint stall independently.
- "Target posted at slide START" needs two mechanisms, one per direction. Show: the snap's own layout pass emits the divider post, so the slide code tags that pass with the duration (`pendingStripSlideDuration`) rather than posting itself. Hide: the display mode only changes in the completion, so the slide start posts the TARGET inset (0) explicitly and the completion's layout pass dedupes to silence.
- A canceled slide's animation completion still fires (finished=false), and it used to run the settle into the NEXT slide — unfreezing mid-motion, the exact flicker the freeze prevents. The cancel bumps a slide epoch; a completion from a stale epoch does nothing. The contract test fires the canceled settle's held snapshot mid-new-slide to pin this.
- The strip applies the payload clock only to the slide's one big jump (>40 pt); the dense small deltas of a live divider drag stay instant, and an untagged post (bind replay) is instant too — a replayed inset is state restoration, not motion.

AppKit shell (2026-10-16), what porting it taught:

- AppKit resets a layer-backed view's layer `transform` when it lays the view out, and the hide re-lays the editor column out in the slide's completion. The slide animation therefore holds its end state itself (`fillMode = .forwards`, not removed on completion) until `chalkEndSlide`; with a removed-on-completion animation the content snapped to the untranslated frame for the frames before the settle's snapshot arrived.
- The settle cover's bitmap is placed from the PRESENTATION layers (`presentedTranslation`), not from `NSView.convert` (frames only) nor the model transform (reset, see above). Either placed the bitmap a sidebar's width from the content it covered, where it faded as a ghost.
- Recorded, not eyeballed: `scripts/screenshots/winrec.swift` records one window as a frame sequence through ScreenCaptureKit, and `CHALK_DEBUG_SCRIPT` drives the shell on a clock, so a one-frame ghost shows up as a number in a per-frame measurement.

### Tab switch

- Moves: an alpha cross-fade between the outgoing and incoming surface views over `motionFast`, with both views hosted for the duration of the fade; and, since Paper (2026-08-24), the accent underline SLIDES to the new name on the same clock, ease-out.
- Never moves: the geometry of either surface, and the incoming surface already carries the current theme and chrome-top inset before it becomes visible. The names themselves never move — only the mark under them.
- Test: both views hosted during the fade and exactly one after it, plus the theme and inset ordering; `TabNameRowTests` pins the underline's placement and that it slides on a SWITCH and stays still on any other rebuild.

The underline belongs to the ROW, not to a tab, and that is what makes the slide possible: every model change rebuilds the names, so a per-tab accent could only ever blink. What building it taught:

- A rebuilt row is not measured when the row's own layout pass runs. The new active name reported 0x0, the underline hid itself, and nothing scheduled another pass — so it stayed hidden for the rest of the session. The placement now settles the row's subtree first, and treats an unmeasured name as "try again next pass" rather than as "no active tab": hiding on a transient zero is a flicker, not a state.
- Both hosts do the same thing in their own idiom (`UIView.animate` / `NSAnimationContext`), from one clock token, because the row exists twice.

Implemented 2026-08-24 (C2); what building it taught:

- A rapid A→B→A switch brings the fading-out view back as the ACTIVE surface while the A→B fade's completion is still pending — the completion must never remove the view the active tab currently owns (`TabSwitchContractTests` pins it by switching back mid-fade).
- AppKit (2026-10-16): a new tab's `WKWebView` composites one WHITE frame when its page process first paints, and alpha 0 on the web view did not stop it (the content is a remote layer). The surface keeps an opaque editor-toned cover over the web view until the page reports `ready` and has painted two frames (`PrePaintCoverView`, lifted on a double rAF with a 0.5 s backstop).
- Tab CLOSE keeps its instant surface swap: `performClose` tears the closing surface down before the neighbor activates, so there is no outgoing view to fade — the close's motion is the chip fade (`motionTab`/`motionFast`), as the tokens table always said.
- The ordering rule is pinned by a DEBUG event trail on the activate path (appearance, chrome-top, install), not by intercepting the webview — install is the moment a surface can first become visible, so "dressed before install" is the testable form of "dressed before visible".

### Zen / normal (focus and typewriter change only the writing surface)

Moves: the name row and the pill fade (`motionStandard`); Library leaves through the sidebar slide; the page's resting offset glides by FLIP (set `--chalk-chrome-top`, counter-translate, transition the transform to 0) so the caret keeps its screen position.
Never moves: the webview bounds; the editor column edges.
Mac windowed: default is the faded-strip lane (chrome fades, titlebar stays); the collapsed-titlebar lane resizes the window content and cannot glide (owner decision recorded in the night report).
Test: resting line identical through a round trip; transition matrix equality.

Implemented 2026-08-24 (C3); what building it taught:

- The fade lane did NOT cascade, so the collapse lane was later removed outright (it had survived as a never-selected `MacZenStripLane.collapse` fallback). The zen path posts the fade, `TabChromeOwnership` keeps the strip FADED through every ownership re-application ("reset to shown" would stand visible chips over a zen window) and `MacStripExpectation.forState`'s windowed-zen expectation is visible+faded.
- AppKit hit-tests `alphaValue`-0 views, so the glue HIDES the strip after the fade-out completes and un-hides before the fade-in; `setChromeVisible` (full-screen exit re-shows the toolbar unconditionally) also respects a standing chip fade. The fade's clock rides the `setFaded` payload (`duration`); an untagged post keeps the glue's auto-hide 0.22.
- On the fade lane, windowed-Mac zen does not move the resting offset at all: the transparent titlebar keeps its height and stays the reserving chrome, so `restingLineSitsOneLineBelowTheReserve` holds with no glide. The glide shows where a band is actually reclaimed: full screen (band → 0).
- The FLIP is really two mechanisms: a SCROLLED document absorbs the whole delta in `scrollTop` (the text under the caret does not move — pinned by a Playwright check that `coordsAtPos` is identical before and after), and only the residual a resting document cannot absorb is transform-glided. The transform rides `#root` (the host shell's mount element, an ancestor CM6 does not own); the padding itself never transitions (CM6 reflows per animated frame and the caret layer lags). Reduce Motion / `.instant` take the plain var set — placement, not motion — which also means a scrolled document keeps its (pre-C3) caret jump there; recorded, not fixed.
- Construction is placement: `ChromeMatrixHost.makeRoot` drives configuration under `.instant` and restores the caller's policy, because a zen cell built on `.system` returns mid-fade and poisons the fresh-layout cache.
- The band presence has one seam (`setBandHidden(_:fadeOver:)`): zen passes a duration, every other presentation pass stays instant, and both lanes land `isHidden` set + alpha 1; a stale fade-out completion is epoch-discarded so a rapid re-toggle cannot hide the band it just re-showed. The H-6 no-glue Mac fallback keeps its snap outright — hiding that band resizes the columns through the safe area, a webview bounds change no fade can mask.
- Test: `ZenTransitionContractTests` (t=0 facts on the animated lane, fresh-layout equality for enter and round trip, instant-lane end-state identity, the strip decision against the oracle, the glide request with its clock).

### Appearance (light/dark)

Order: snapshot the webview (old colors) -> opaque cover -> in one turn: trait flip + `data-theme` push + per-chrome-view cross-dissolve (`motionStandard`) -> in-page paint gate -> cover fade (`motionFast`).
Never: a frame showing the new native chrome over the old page colors or the reverse.
Reduce Motion: same covers, zero-duration fades.
Test: ordering probe (cover before trait flip, gone after gate/backstop).

Implemented 2026-08-24 (C4); what building it taught:

- `WebPaintGate` was reused unchanged — the appearance transition is the sidebar settle with `reflow` = "the one covered turn" (override flip + `data-theme` push + the three chrome dissolves + the presented-sheet walk) and no geometry change.
- The dissolves run on headerBar, footerBar and the sidebar's view SEPARATELY, begun before the flip in the same turn: `UIView.transition` captures each view's old-theme presentation at call time and cross-fades to whatever the turn's trait flip restyles. The root view is never transitioned — its snapshot includes the webview's remote layer, which comes back empty.
- The SYSTEM route (Auto) cannot honor "cover before the trait flip": the OS has flipped the trait — and the native chrome — before `traitCollectionDidChange` fires. What the cover still owns there is the page's slower async repaint, the torn half; the container's own trait hook stands down while a root orchestrates (`hostOwnsAppearanceTransitions`), so the page can only flip UNDER the cover on either route. The honest system-route contract is "page flips only under the cover", and that is what the probe asserts.
- The cover's background is the DYNAMIC editor color on purpose: it resolves old at install and re-resolves new when the trait flips beneath it, so the frame around the old-pixels bitmap never disagrees with the incoming chrome (and a dead-snapshotter cover degrades to a plain new-color sheet).
- The preference route is guarded on a real override change — the Settings broadcast re-applies on every general change, and an unchanged preference must not flash a cover. A rapid re-toggle cancels the previous settle (its late gate answer is a no-op) so an old cover never fades over the newer transition's pixels. A root with no hosted surface (viewDidLoad, no tabs) applies directly; nothing can tear.
- Test: `AppearanceTransitionContractTests` (ordering probe on both routes, unchanged-preference no-op, `.instant` standing in for Reduce Motion with the cover kept, the paint backstop, the rapid-toggle cancel).

### Fullscreen (Mac)

The ownership swap (AppKit strip <-> UIKit band) happens at the will-transition edge so the system animation carries the final chrome; the incoming band fades in over `motionFast`.
Test: transition matrix equality windowed<->fullscreen; the screenshot diff lane for the visual half.

### Palettes (Quick Open, outline)

Existing 0.10 fade + 6 pt rise + 0.97 scale is kept; Reduce Motion instant.

### Auto-hide chrome

Existing 0.22 translate+fade is kept; ownership re-applied to both chromes on every ownership change (`TabChromeOwnership`).

## Verification

- Contract tests: `ChalkTests/SidebarSlideContractTests`, the ordering probes, and `ChromeTransitionMatrixTests` equality with fresh layouts.
- Real pixels: `scripts/ui-transition-diff.sh` (fresh state vs same state reached through a path; zero-diff oracle).
- Smoothness: the DEBUG jank probe logs `CHALK_MOTION <name> frames=<n> hitches=<m>` around each transition; watched, not gated, until the numbers are stable.
