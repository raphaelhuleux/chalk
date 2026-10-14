# Tab drag-reorder design (2026-07-23)

## Goal

Rearrange open tabs by dragging chips in the tab strip, on both surfaces:
the AppKit titlebar strip (Mac Catalyst) and the UIKit `HeaderTabStrip` (iPad).

## Model

`EditorContainerViewController.tabs` is the per-window source of truth; both
strips are stateless renderers rebuilt from `TabItem` snapshots. Reorder is a
single new entry point:

- `EditorContainerViewController.moveTab(id: UUID, to index: Int)` — remove +
  insert in `tabs` (index clamped), then `refreshTabBar()`. Active tab, dirty
  state, surfaces are untouched; session restore already serializes `tabs` in
  order, so persistence needs no change.

## Mac (ChalkTabStrip.swift, AppKit)

Safari-style immediate drag:

- `TabChipView` already swallows `mouseDown` (titlebar drag-grip rule) and
  selects on `mouseUp`. Add `mouseDragged`: a 4pt horizontal threshold starts a
  drag; past it the chip follows the cursor via a translation-only layer
  transform (clamped to the stack's bounds), raised zPosition.
- Live reorder: when the chip's visual midX crosses a neighbor chip's midX,
  move it in the stack's arranged list and recompute the transform so the chip
  stays under the cursor (track desired visual minX = cursor − grab offset).
- Drop (`mouseUp` after a drag): clear the transform, post the new bridge
  action `move` with `id` + final arranged index. No `select` fires. A click
  without crossing the threshold still selects.
- The strip defers `update` notifications that arrive mid-drag (they rebuild
  all chips and would destroy the dragged one); the last deferred snapshot is
  applied when the drag ends.

## iPad (HeaderTabStrip.swift, UIKit)

`UIDragInteraction` + `UIDropInteraction`, local-only — press-and-move lifts
the chip, plain long-press still opens the existing context menu (the system
arbitrates the two), and the strip's scroll gesture is untouched:

- Each chip gets a `UIDragInteraction`; drag restricted to the app; the drag
  item carries the tab id in `localObject`.
- The strip gets a `UIDropInteraction`: `sessionDidUpdate` proposes `.move`
  and live-reorders the arranged chips from the session location;
  `performDrop` fires the new `onMove: ((UUID, Int) -> Void)?` callback; a
  cancelled session restores the original order (next `update` rebuilds).
- `update(_:)` mid-drag is deferred exactly like the AppKit side.

## Wiring (RootSplitViewController)

- `handleTabStripAction`: new `case "move"` → `editor.moveTab(id:to:)`.
- `headerBar.tabStrip.onMove = { [weak self] in self?.editor.moveTab(id: $0, to: $1) }`.

## Out of scope

- VS Code host (has native tabs) and `HostPort` (tab UI is native-only).
- Dragging tabs between windows.
- Overflow-menu reordering.

## Testing

- `ChalkTests/TabReorderTests`: `moveTab` reorders, clamps out-of-range
  indices, no-ops on unknown id, republishes via `onTabsChanged`, and keeps
  the active tab active. Runs on the iPad simulator (Catalyst can't host the
  test bundle).
- Drag gestures verified manually / via the Catalyst audit build.
