# The first Location creeps up under the traffic lights after full screen

Reported by the owner (2026-08-18), and previously chased three times through
the wrong layer: windowed → full screen → windowed, with the Library shown,
changed the gap between the macOS traffic lights and the first Location header.

## What it was not

Measured live on the running Catalyst app at each stop of the round trip, the
panel, the column, the titlebar and the lights were all identical:

| | W1 (windowed) | W2 (after the round trip) |
|---|---|---|
| panel in window | `{{13, 13}, {394, 1341}}` | same |
| column in window | `{{-100, 0}, {507, 1367}}` | same |
| titlebar height / close button | 52 / `{{19, 1018}, {14, 16}}` | same |
| **collection contentOffset.y** | **38** | **47…61** |
| **first header y** | **28** | **19…6** |

So no chrome moved. The Library was left SCROLLED, by exactly the column's
safe-area top.

## Root cause

On Mac the titlebar reaches the Library's column as its safe-area top, and full
screen takes it away (the glue hides the toolbar going in, restores it coming
out). Three UIKit mechanisms read that band and moved the list:

1. `UICollectionViewCompositionalLayout.list(using:)` defaults every section's
   `contentInsetsReference` to `.safeArea`, folding the band into the section
   geometry.
2. Cell layout margins inherit the safe area, so the first Location header
   measured 85pt with the band against 62pt without — a 23pt difference, the
   band exactly.
3. `UICollectionView` then re-anchored its own scroll offset to keep the
   visible content stationary. Stack-verified on the running app:

   ```
   -[UICollectionView _setContentOffsetWithoutClearingAnchorOrScrollTarget:]
   -[UICollectionView _restoreOrAdjustContentOffsetIfNecessaryWithInsets:hasUpdatedVisibleCells:isRecursive:]
   -[UICollectionView _updateVisibleCellsNow:]
   ```

`contentInsetAdjustmentBehavior = .never` does not cover (3): it governs
`adjustedContentInset`, not the anchor restore.

Two conditions had to hold, which is why it looked intermittent: the Library
must be long enough to scroll (a list shorter than its column cannot drift), and
the safe-area change must land together with the window resize.

The hand-calibrated `contentInset.top = -s(29)` had been measured on screen
while the band was inflating the first header, so the old "correct" spacing was
itself a side effect of the bug.

## Fix

Two statements of one rule — the panel places itself against the safe area, and
nothing inside it may spend that band a second time:

- `SafeAreaFreeCollectionView` (`safeAreaInsets` → `.zero`) for the tree, so no
  section inset, cell margin or anchor restore can see the band.
- The band is reserved through `treeTopClearance(safeAreaTop:)`, applied to the
  tree's TOP CONSTRAINT (the collection view's frame). A frame change never
  moves scroll content, so the list rests where it rested. The tree starts at
  the titlebar's bottom edge while there is one and at its spec padding when
  there is not (full screen, iPad).

## Verification

- `ChalkTests/SidebarSafeAreaGeometryTests` — 5 tests. The guard
  (`testTheListIsSafeAreaFree`) fails at clean HEAD (safe area 40 vs 0) and
  passes with the fix.
- Full `ChalkTests` suite on the iPad simulator: 271 tests, 0 failures.
- Live Catalyst round trip driven by a real ⌃⌘F keystroke: the sidebar's
  top-left region (lights + first Locations) is **pixel-identical** before and
  after, 0 differing pixels.
- iPad is untouched: the tree measures byte-identical before and after
  (`panel=(10, 32, 824, 1168)`, `header=(18, 48, 808, 35)`, `offset=8`), because
  the iPad panel already starts at the safe area, leaving the list none.
