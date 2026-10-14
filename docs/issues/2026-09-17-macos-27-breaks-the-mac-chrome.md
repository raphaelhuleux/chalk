# macOS 27 breaks the Mac chrome

Status: **fixed 2026-09-17.** iPadOS 27 was checked the same day and was never affected.

## Symptom

First build and install on macOS 27 (Xcode 27, macOS 27 SDK; the previous host was macOS 15).
The installed Release build came up with:

- a second, empty bar under the tab row, ending in a hairline about 105pt (Mac) below the window's top edge;
- the document's first heading hidden behind that bar (and, on the first launch of the Release build, no text visible at all);
- a thin dark vertical line standing in the tab row just right of the traffic lights;
- with the Library open: tabs left at the traffic lights instead of the divider, and the band painted over the panel;
- the Library jumping back to the top after it had been scrolled.

The signature was valid and the AppKit glue was loaded, so none of the three silent install failures in `.claude/skills/install-mac` applied.

## Root cause

Not one bug. The Mac had skipped macOS 26, so Liquid Glass and macOS 27's Catalyst changes all arrived in one step.
Five independent assumptions stopped holding:

1. **The editor column's navigation bar draws.**
   `UISplitViewController` wraps the secondary column in a `UINavigationController` of its own.
   Nothing hid that bar, because an empty bar used to draw nothing.
   On macOS 27 it is a 54pt bar *below* the titlebar with a material background: `UINavigationBar (0 85; 1330 54)`, `_UIBarBackground (0 -85; 1330 139)`, over text that rests at 112.
   Fix: `EditorContainerViewController.viewWillAppear` hides it, as the Library always has for its own.
2. **The web view's scroll view grew a top edge effect** (`ScrollEdgeEffectView`, 140pt) to match that bar.
   The scroll view never scrolls (CodeMirror scrolls its own element), so the effect can only be wrong.
   Fix: all four edge effects hidden in `WebEditorSurface.init`.
3. **The titlebar spacer got a glass platter.**
   The glue's toolbar holds the titlebar open with a 1x46 spacer item.
   Liquid Glass seats every bordered item on a platter: `NSToolbarPlatterView f=(114,12,1,46)`, a 1pt dark line.
   Fix: `item.isBordered = false`.
4. **Catalyst tiles the split view the iPadOS 26 way.**
   The secondary column's frame stays full-size and the Library is carved out of its safe area.
   The Mac's `measuredBandInputs` read the bare column origin, so the divider was 0 with the Library open.
   The same change had already reached iPad, where Catalyst was unaffected. It was, until now.
   Fix: origin + `safeAreaInsets.left`, the iPad's sum.
5. **The Library's first header is pinned.**
   `trimLeadingListPadding` measures the list's leading padding off that header's layout attributes.
   A pinned header reports where it is pinned, so a list scrolled to 120 measured a padding of -120; offset plus inset then summed to zero, which is what "at rest" looks like, and the next honest measurement put the list back at the top.
   Fix: measure only at rest, where the pinned and natural positions are the same point.

## How it was found

`ChromeInvariantMatrixTests` went red on the Mac in exactly the sidebar cells (`stripLeadingTracksTheDivider`, `libraryIsNeverPaintedOver`, `nameRowClearsTheLibrary`), which named cause 4 outright.
`ChromeTransitionMatrixTests.testFullscreenRoundTripKeepsTheLibraryWhereItWas` named cause 5; a temporary `contentOffset` observer gave the call stack.

Causes 1 to 3 are rendering faults, the class [ui-correctness.md](../ui-correctness.md) says frames cannot express, and no test saw them.
They were read off the live hierarchy: `lldb -p`, `recursiveDescription` on the key `UIWindow`, `_subtreeDescription` on the `NSThemeFrame`.
Attaching needs `get-task-allow`, so that was a copy of the Debug product re-signed ad hoc with only that entitlement (never the sandbox one; see the install skill).

## Verification

- Mac Catalyst, macOS 27: `ChalkTests` 500 tests. Green, except `TabSwitchContractTests.testSwitchKeepsBothSurfacesHostedThenExactlyOne`, which fails when another `xcodebuild` is competing for the machine (it waits a fixed 0.2s past the fade) and passes alone. Not caused by this work.
- iPad Pro 11-inch (M5) simulator, iPadOS 27.0: `ChalkTests` 497 tests, 0 failures, before and after.
  Screenshots of the editor and of `sidebar-deep` are identical with and without the fixes.
- The reinstalled Release build, by screenshot: heading directly under the tab row, no bar, no line; `sidebar-deep` on the Debug build shows the tabs at the divider.

## Not done

The first Release launch showed no document text at all, where the Debug build showed the text with only the heading covered.
The fixed Release build renders correctly and the difference was not chased further; if a blank editor comes back, start from the edge effect's backdrop capture (cause 2), which is the one piece that sat between the web content and the screen.
