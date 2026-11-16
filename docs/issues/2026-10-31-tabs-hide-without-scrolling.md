# The tab band hides without the reader scrolling

Status: **fixed for jumps, 2026-10-31; fixed for height corrections, 2026-11-06.** Not proven to be every report of the band disappearing.

## Symptom

The tab band disappears "sometimes", and stays gone until the reader scrolls up or moves the pointer to the top.

## Cause

Auto-hide read every `scrollTop` change as scrolling.
A real web view hid the band after `window.__chalkEditor.gotoLine(1000)` from the document top, with no scroll input.
Outline clicks and PDF Cmd-clicks use the same jump path; reflows that move `scrollTop` would count too, though a probe of those was inconclusive.
Nothing then reveals the band, since no further scroll arrives.

## Fix

`native-host.ts` marks a `scroll` post `wheel` when a wheel event landed in the last 200 ms, and `ChromeAutoHidePolicy.observe(offset:canHide:)` only hides on those.
Keyboard paging and typing past the bottom no longer hide the band.
Regression: `ChromeAutoHidePolicyTests.testAMoveTheReaderDidNotScrollNeverHides`.

## Second cause: height corrections against the wheel (2026-11-06)

Reported again after the fix above was installed.
Wheeling UP through a document CM6 has only estimated (after a jump, a reopen, or far from where it last rendered), CM6 swaps estimated line heights for measured ones and moves `scrollTop` DOWN to keep the view steady.
Display math is much taller than the estimate, so one frame moved 180 to 400 px down, inside the wheel window.
The post was marked `wheel`, the policy read it as the reader scrolling down, and the band hid while the reader scrolled toward it.
Usually the next 12 pt of upward travel brought it back (a flicker); when the correction landed at the end of the gesture, it stayed hidden.
Measured in WebKit and Chromium on a 60-equation `.tex` document: two or three such frames per 2,400 px of upward wheeling.
No correction ran against a downward wheel in the same probe.
Text-only Markdown hits it too once the column narrows, which is what opening the PDF slot does: every paragraph re-wraps and the heights CM6 had measured go back to estimates.
In a 120-paragraph `.md`, wheeling up after the column went from 1500 to 800 px gave four corrections of 61 to 143 px, each a hide; with no resize, or a widening one, there were none.

Fix: `attachScrollReporter` remembers the sign of the last wheel `deltaY` and marks a frame `wheel` only if `scrollTop` moved that way since the previous post.
Regression: `Tests/browser/run.mjs` scenario "scroll telemetry: a height correction against the wheel is not the reader", which fails on the old bundle with corrections of 59, 321 and 400 px marked `wheel`.

Toggling zen off within `motionStandard` of turning it on left the band hidden outside zen: `setBandHidden(false, …)` returned at its `isHidden` guard before bumping `zenBandFadeEpoch`, so the fade-out's completion still set `isHidden = true`.
Fixed 2026-11-16 with the other tab-row regressions ([2026-11-16-tab-row-regressions.md](2026-11-16-tab-row-regressions.md)).
