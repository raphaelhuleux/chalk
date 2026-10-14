# Switching tabs sometimes needs two clicks

Reported 2026-08-18: clicking a background tab occasionally does nothing, and the second click works.

## Which strip

Only the UIKit strip ([HeaderTabStrip.swift](../../mac/Chalk/Tabs/HeaderTabStrip.swift)), which is the tab UI on iPad always and on Mac in full screen.
The windowed Mac strip is the AppKit one and was already immune: it tracks the press in its own run loop and treats a release that never left the slot as a click (`ChalkTabStrip.swift`, 2026-07-23).

## Root cause

The chip is a `UIControl` that selects on `.touchUpInside` alone, and two things cancel that touch without any fallback.

1. **The drag-reorder lift.** For an indirect pointer (Catalyst mouse, iPad trackpad) `UIDragInteraction` lifts on press plus a few points, with no long-press delay. The lift cancels the control's tracking, so `.touchUpInside` never fires; the chip then drops back into its own slot, so `performDrop` reports an unchanged index and `moveTab` early-returns. The click did nothing.
2. **A rebuild landing mid-press.** `rebuild(_:)` drops every chip and builds new ones. An `update(_:)` arriving between touch-down and touch-up destroys the pressed chip and the action it owed. Updates were parked mid-drag only, not mid-press. Triggers: a save confirming, a dirty flip, a rename.

A third path, the scroll view claiming a finger pan, is left alone on purpose: a 10pt pan is a deliberate scroll, and not selecting is the right outcome. Indirect-pointer presses do not drive the scroll view's pan, so this path never affects a mouse click.

## Fix

- `dragInteraction(_:session:didEndWith:)` records the chip's index at `sessionWillBegin` and selects the tab when the session ends at that same index. This is the UIKit half of the AppKit rule; the threshold has to be recovered at the end of the session because `UIDragInteraction` owns its gesture.
- `HeaderTabChip` reports its press lifecycle (`beginTracking` / `endTracking` / `cancelTracking`) and the strip parks updates during a press, exactly as it does mid-drag. The replay is deferred one run-loop turn, because `UIControl` sends `.touchUpInside` after `endTracking` returns and a synchronous rebuild would destroy the chip first.
- `latestItems` now records every update, parked ones included, so a replay rebuilds from the newest model rather than the first parked one.

## Tests

`ChalkTests/TabClickJitterTests` drives the real drag and drop delegate methods through hand-built session fakes.
Full suite after the fix: 278 tests, 0 failures, 3 skipped.

Not yet confirmed by hand on a device or in the running Mac app.
