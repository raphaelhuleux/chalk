# Editor tab groups

Side-by-side tab groups on the Mac, modelled on VS Code's editor groups and Obsidian's tab groups.
They replace the two-pane split.

## Behaviour

- The editor is a flat row of columns: any number of groups side by side, no vertical splits, no nesting.
- Each group has its own tabs, shows one of them, and has its own row in the title band, over its column.
- A tab lives in exactly one group. Opening a file shown in another group focuses that group; it never opens a second tab.
- One group has focus. Commands, ⌃Tab, the outline and the PDF slot act on its shown tab. Unfocused rows draw their underline in the inactive tab colour.
- A click in a pane focuses its group without stealing the click.
- Closing a group's last tab closes the group; its width goes to a neighbour. The last group never closes.
- Seams drag; only the two groups beside a seam change width, and none goes under `ChalkMetrics.groupMinimumWidth` (320 pt) unless the column is too narrow for every group, in which case they share it evenly.

### Commands

| Command | Key | Notes |
| --- | --- | --- |
| Split Editor Right | ⌘\ | Moves the focused tab into a new group on its right. Beeps when the group has one tab or no column fits. |
| Focus Next Group | ⌥⌘\ | Wraps. |
| Focus First / Second / Third Group | ⌘1 / ⌘2 / ⌘3 | VS Code's chords. |
| Join All Groups | none | Every tab back into one group, in row order. |

The tab context menu adds Split Right, Move to Left Group, Move to Right Group and Close Group. ⌥-click moves a tab to the group on its right, making one if needed.

### Dragging a tab

The row keeps the mouse tracking after the lift (4 pt), and `TabDragSession` decides at each move:

- Over its own row: the reorder it always had. A lift that ends in its starting slot is a click.
- Over another row: a 2 pt marker shows where it lands; the drop inserts it there.
- Over an editor: `TabDropPolicy` picks the zone, as VS Code's `editorDropTarget.ts` does.
  - More than 10% of the width and height from every edge is the center: join that group. The indicator covers the group.
  - Otherwise the leading third splits leading and the trailing third splits trailing. The indicator covers that half. VS Code's top and bottom bands count as center, since groups never stack.
  - A split that would not fit falls back to center.
  - Over the tab's own group, each half splits toward its side, so the whole group shows a target. VS Code's center there shows nothing and drops nothing, which read as a drop that did not take. A group's only tab, or a group with no room for another beside it, still shows nothing.
- Over anything else: nothing shows and the drop does nothing.
- Escape cancels.

A drop focuses the group the tab landed in. A group left empty closes.

## Model

- `EditorGroup` (app) holds the tabs, the shown tab and the pane. `EditorContainerViewController.groups` is never empty.
- `EditorGroupsLayout` (ChalkKit) holds the width fractions, the floor rule and insert/remove/resize arithmetic.
- `TabDropPolicy` (ChalkKit) holds the zone rule and the indicator rect.
- `EditorPaneHostView` places panes, seams and grips by frame and owns the drop overlay.
- `HeaderBarView` keeps one row per group. Rows are placed by constraint constants pushed from the live pane frames (`setGroupColumns(seams:)`), never constrained to a pane view.

## Session

`WindowSession` v2 records `groups` (tabs, shown index, width fraction) and `activeGroupIndex`.
A v1 record (`tabs`, `activeIndex`, `splitIndex`, `splitIsLeading`) decodes into one group, or two when it had a split, with the split tab alone in its group. Only v2 is written.

## Chrome invariants

The matrix's split axis became a groups axis: one group, or three (the first row's inset, an interior row and the last row's outline cut).
Three rules cover it: `editorGroupsKeepTheirFloor`, `groupDividersSitOnTheSeams`, `groupStripsLieOverTheirColumns`; `editorPanesTileTheContent` counts three panes. See [ui-invariants.md](../ui-invariants.md).

## Limits

- No dragging between windows.
- One live web view per shown tab, so three groups hold three.
- Rows 2 and on snap to their new place at the end of a Library slide rather than sliding with it.
- The trailing slot's limit is computed from the first row only (`HeaderBarView.stripReadableExtent`).
