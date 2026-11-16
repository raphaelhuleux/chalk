# Tab row regressions: lights, "+", close ×, vanishing names

Status: **fixed 2026-11-16.**

## Symptoms

Reported together on the installed build of 13 Nov:

1. The tab names sat off the traffic lights' centre line (vertically).
2. The "+" was too small, most visibly alone in an empty row.
3. A background tab's hover × sat nearly on the next tab's name.
4. The tabs disappeared "for random reasons", for example after switching between full screen and a window.

## Causes

1. **Short titlebar after a full-screen exit.** `windowWillEnterFullScreen` hides the empty toolbar (in full screen AppKit would draw it as an opaque bar). `windowWillExitFullScreen` shows it again, but AppKit then restores the visibility it saw on entry, so the toolbar stayed hidden and the titlebar came back short (32pt instead of 52pt). The lights moved 10pt up; the band, floored at the row's 46pt, centred the names 7pt below them. Measured in a real window: before the round trip lights and row both at 26pt from the top; after it lights at 16pt, row at 23pt.
2. **"+" protected by its test.** `NewTabGlyphSizeTests` capped the ink at 1.25 capital heights and had no floor. The glyph was 10pt light: 8pt of thin strokes.
3. **Slot widened without the gap.** `tabSlotWidth` went 14 → 18 and `closeGlyphSize` 7.5 → 9.5 with `tabGap` left at 12. A clean background tab's slot hangs past its item into the gap, so its × ink ended 13pt from its own name and 7pt from the next one, and the slot's hit area covered 6pt of the next tab.
4. Three separate causes:
   - **The chevron had no width while shown.** `setOverflowVisible` deactivated the chevron's zero-width constraint and set nothing in its place. The row's layout was ambiguous and Auto Layout could give the chevron the whole row: the names' clip came out 0pt wide, with no error. Overflow is more frequent since tab groups split the band into narrower rows.
   - **A scrolled-away band stayed hidden across a window-mode switch.** `setMacFullscreen` did not reveal the chrome, and the stricter reveal rule (a 100pt flick or a 300pt climb) made it slow to bring back.
   - **Zen off inside zen-on's fade** (open since [2026-10-31](2026-10-31-tabs-hide-without-scrolling.md)): `setBandHidden` returned at its `isHidden` guard before bumping the fade epoch, so the fade-out's completion hid the band outside zen.

## Why the tests missed them

- Test windows were plain titled windows with the short titlebar, so no test ever saw the app's traffic lights. The matrix's full screen is a flag on a windowed window, so the real exit path never ran.
- The "+" test asserted a ceiling only.
- Nothing measured the × against its neighbours, nor any hover or overflow state.
- Nothing checked the row for ambiguous layout.

## Fixes

- `windowDidExitFullScreen` shows the toolbar again once AppKit is done, then re-lays the band (`windowModeDidSettle`).
- `newTabGlyphSize` 13, regular weight.
- `tabSlotWidth` 14, `tabInnerGap` 5, `tabGap` 16: the × is 8pt from its own name and 16pt from the next; the hanging slot ends inside the gap.
- The chevron's width constraint stays active: 0 collapsed, `overflowButtonWidth` shown.
- `setMacFullscreen` reveals the chrome; `setBandHidden` bumps the epoch before its guard; a height change re-applies an auto-hidden band's offset.
- Every band presence change is logged under the `chrome` category, so the next disappearance names its cause.

## Guards

- `NSWindow.hostedForTesting` is the app's window (`EditorWindowController.makeChromeWindow`).
- Catalogue rules `namesShareTheLightsLine`, `firstNameClearsTheLights`, `groupRowsShareOneLine`; on the old short-titlebar window the first fails in 32 windowed cells.
- `TabCloseSpacing` (ChalkKit) and `TabRowGeometryTests`: × placement in every cell, the "+" clear of the names, the overflow row's names on screen, no ambiguous view, and a gallery for a person to look at.
- `NewTabGlyphSizeTests`: the "+" ink in a band (at least a capital and the ×, at most 1.5 capitals).
- `WindowModeRoundTripTests`: a real `toggleFullScreen` round trip with the band scrolled away.
- `ZenTransitionContractTests.testZenOffInsideTheFadeLeavesTheBandOnScreen`.

Each was checked to fail with its fix reverted.

## Not resolved

`ChromeInvariantMatrixTests` once failed `libraryListStartsAtTheChromeFloor` in the 16 full-screen, Library-open, non-zen cells (first run after switching the tests to the tall-titlebar window), then passed three runs in a row. Not reproduced and not explained. If it returns, print `libraryFirstHeaderTop` from the failure dump (it is in the dump now).
