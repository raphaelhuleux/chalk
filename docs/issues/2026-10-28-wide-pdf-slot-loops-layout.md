# A PDF slot wider than the editor column loops layout and aborts

Status: **fixed, 2026-10-28.**

## Symptom

Compile (⌘R) on a Markdown file crashes Chalk as the PDF panel opens, with no message.
It crashed twice in a row, the second time right after a relaunch.
Any way of opening the PDF slot in that window does the same; the compile is not needed.

## Evidence

Two crash reports, 18 seconds apart (`Chalk-2026-10-28-170918.ips`, `-170936.ips`), both `SIGABRT` from an uncaught exception in `-[NSWindow(NSDisplayCycle) _postWindowNeedsLayout]` on the main thread.
The compile queue was still inside `ToolLocator.readLoginShellPath`, so the crash fired while the slot slid in, before pandoc ran: the compile itself is incidental.
The stored `chalk.pdfPanelWidth.appkit` was 983 pt; the window was 1100 pt wide with the Library open at 321 pt, so the column was 779 pt.
A hosted window with those numbers reproduces it; at 400 pt it does not.
The exception reason, from the test run: "The window has been marked as needing another Layout Window pass, but it has already had more Layout Window passes than there are views in the window."

## Cause

Nothing kept the trailing slot inside the editor column: `setOutlinePanelWidth` clamps only to `pdfPanelWidthRange` (320 to 1400), so the 983 pt slot overhung the Library by 204 pt.
The band then cut its trailing hole from that leading edge and pinned the chip strip's trailing edge to it, left of where the strip starts.
That pin and the strip's fixed tail (gap, "+", overflow gap) were both required, and an `NSWindow`'s size only holds at `windowSizeStayPut` (500), so Auto Layout grew the window instead.
A wider window moved the slot, which moved the hole, which let the window shrink back, and the passes never settled.
The outline can hit it too: the Library at 560 pt in a 680 pt window leaves a column narrower than the outline's 220 pt minimum.

## Fix

- The strip's trailing pin sits just below `windowSizeStayPut`: a hole the chips cannot fit beside overlaps them and can no longer resize the window (`HeaderBarView`).
- The slot shows its preferred width fitted to the column, short of the chips' narrowest strip (`EditorContainerViewController.fitSlotWidth`, limit from `HeaderBarView.stripMinimumExtent`), but never below the content's minimum (220 pt outline, 320 pt PDF). The preference is kept, so a wider window gets the full width back. Below that minimum (a tiny window with a wide Library) the slot still overhangs, and the first fix keeps that harmless.
- Regression: `PDFPanelSlotTests.testAPDFWiderThanTheColumnFitsItAndTheWindowKeepsItsSize` crashes the test host with the same exception on the old code.
