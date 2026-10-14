# Outline panel design

Date: 2026-09-04.
Host: native app only (Mac Catalyst).
Status: implemented 2026-09-04, verified on the iPad simulator and on a Mac Catalyst install 2026-09-05.

Follow-ups found during verification:

- `ChromeTransitionMatrixTests` is now red on every whole-bundle Mac Catalyst run, where it was red on roughly one run in four before this work.
  Every complaint is the documented "displayMode says sidebar shown, expected nosidebar" settle race on a path that shows the Library and then hides it, and no complaint names the outline panel's own rect or rules.
  The likely mechanism is arithmetic: the state matrix doubled from 32 to 64 cells, so one test method now walks twice as many toggle paths and the pre-existing race fires almost every run.
  Measured: branch 5 of 5 whole-bundle runs red, pre-outline tip (`9e745ef`) 3 of 4 green, `main` 4 of 4 green.
  The suite passes when run alone on the branch, so this is a settle problem, not a layout defect.
- In overlay mode the editor text runs under the panel and is cut mid-word at its leading edge.
  That is what this spec asks for, and it looks like clipped text rather than a panel over a page.
  Worth a second look at whether the overlay should dim or fade the column beneath it.
- The open and close animation was verified by before and after captures only.
  Its smoothness, and whether the reflow reads worse than the Library slide, is not assessed here.
- The ⌘K keyboard lane could not be exercised on the iPad simulator.
  No Command shortcut reaches the guest app on this host, including ⌘P, which predates this work.

## Goal

A persistent outline panel on the trailing edge of the editor, toggled with ⌘K.
It looks and behaves like the ⌘J Library sidebar: a full-height column, resizable, remembered per window.
It lists the same items the ⌘P outline palette lists, highlights the section the caret is in, and refreshes as the user types.
The palette stays as it is: ⌘P, the footer pill and the iPad swipe are unchanged.

## Non-goals

- VS Code has no outline panel in this change.
- No search field in the panel; search stays a palette feature.
- No richer item set (labeled equations, tables); the extractor in editor-core is reused as is.
- No third `UISplitViewController` column.

## Decisions from the interview

| Question | Decision |
|---|---|
| Contents | Same items as the palette: `extractOutline` output |
| Tap on a row | Move caret there, scroll it to the top, focus the editor, panel stays open |
| Live sync | Highlight the current section and refresh on edit |
| Coexistence with the Library | Independent, both may be open; overlay on narrow widths |
| Persistence | Per window, like `isSidebarVisible` |
| Shortcut | ⌘K toggles the panel; ⌘P palette unchanged |
| iPad pill and swipe | Stay on the palette |
| Shape | Resizable, no search |
| Mac geometry | Panel pinned inside the editor column, not a split column |

## 1. Layout and geometry

`OutlinePanelViewController` is a child of `EditorContainerViewController`.
It is pinned to the container's trailing safe-area edge and runs the full height of the column below the band, using the same top clearance the content view gets from `setTopClearance`.

Two modes, chosen from the container width at layout time:

- Push mode: the content view's trailing constraint moves from the safe-area trailing anchor to the panel's leading anchor. The editor shrinks.
- Overlay mode: used when `containerWidth - panelWidth < 480pt`. The content view keeps its full width and the panel floats above it with the editor background color and a leading hairline separator.

The threshold is a constant in `ChalkMetrics` (`outlinePanelPushMinimumEditorWidth`), not a magic number in the controller.

Width defaults to the platform's `ChalkMetrics.sidebarWidth`.
A leading-edge drag handle resizes it, clamped to `Preferences.sidebarWidthRange`.

Zen refuses to open the panel and closes it on entry, the same rule the Library follows.

Open and close animate with `ChalkMetrics.motionSidebar` as a plain constraint animation.
No `WebPaintGate` episode: the webview reflows inside the container instead of sliding under chrome, so there is no frozen-content trick to settle.

### Layout oracle and invariants

- `ChromeLayout` gains `outlinePanel: CGRect?`, nil when hidden.
- `UIState` gains an `outline` axis with raw ids `outline` and `nooutline`. `UIState.matrix` doubles to 64 cells.
- `RootSplitViewController.chromeLayout(for:)` reports the panel's frame in root coordinates.
- New invariants in `ChromeInvariants`:
  - `outlinePanelReachesTheWindowEdges`: the panel's maxX equals root maxX and its maxY equals root maxY.
  - `editorContentClearsTheOutlinePanel`: in push mode `editorContent.maxX <= outlinePanel.minX`.
  - `outlinePanelSharesTheEditorTop`: the panel's minY equals `editorContent.minY`. On Mac both run full-bleed under the transparent titlebar; on iPad both sit under the band.
  - `outlinePanelMatchesState`: `state.outline == .shown` iff `outlinePanel != nil`, asserted in `ChromeInvariantMatrixTests` next to the sidebar coupling.
- `docs/ui-invariants.md` is regenerated; `scripts/check.sh` guards the drift.
- The zen cells remain deliberately red, as documented in `docs/known-failing-tests.md`.

## 2. Push channel

The outline is pull-only today: one `evaluateJavaScript` per palette open.
A live panel needs a push, and the push must cost nothing while the panel is closed.

### editor-core and web

- `mountEditor` returns `setOutlineSubscription(on: boolean)`.
- When on, a compartment installs an `EditorView.updateListener`. On `docChanged` or `selectionSet` it schedules a snapshot after 120ms of quiet and calls a supplied `onOutline(snapshot)` callback.
- When off, the compartment is empty. Keystrokes pay nothing.
- A selection-only change recomputes the full outline; the debounce bounds the cost.
- `web/src/native-host.ts` exposes `window.__chalkEditor.setOutlineSubscription(on)` and posts `{type: 'outline', items, cursorLine}` to the host. This is transport-internal, like `scroll` and `resolve-asset`. The frozen 9-message `HostPort` protocol is unchanged.

### Swift

- `WebEditorSurface` decodes `outline` into the existing `OutlineSnapshot` and forwards it via a new `onOutline: ((OutlineSnapshot) -> Void)?`, next to `onScroll`.
- `EditorSurface` gains `setOutlineSubscription(_ on: Bool)`.
- `EditorContainerViewController` owns the subscription:
  - On panel open: seed with one `fetchActiveOutline` pull so the panel fills at once, then subscribe the active surface.
  - On tab switch while open: unsubscribe the old surface, seed from the new one, subscribe it.
  - On panel close: unsubscribe.
- A snapshot arriving for a surface that is no longer active is dropped, guarded by tab identity as `presentOutlinePalette` already does.

## 3. Panel view

Revised 2026-09-05 to the "document header" artboard the owner picked (design canvas: Chalk Outline Panel).

- A full-height chrome column like the Library: `chalkChromeBackground`, a hairline on its leading edge, reaching the window's top.
- A document header up in the band, `s(26)` from the panel's top: an "OUTLINE" eyebrow (11pt semibold, letter-spaced, `chalkTextFaint`) over the active document's name (13pt semibold, `chalkChromeFg`), then a hairline rule.
- The list starts under the rule with `s(6)` of padding, ignores the safe area (`contentInsetAdjustmentBehavior = .never`) and ignores the text's resting inset.
- Rows are `s(32)` tall, no kind glyph, in `OutlineTreeRowCell`: the title steps in `s(15)` per nesting level from a `s(14)` start, one hairline tree guide per ancestor level, ink that quietens with depth (level 1 semibold `chalkChromeFg`, level 2 `chalkChromeFgSecondary`, deeper `chalkTextSecondary`).
- Nesting comes from `OutlinePalettePolicy.indentLevels(for:)`; the current section from `preselectedIndex(items:cursorLine:)`, tinted with `chalkAccentSelection` at the palette's row radius. The table scrolls to it only when it leaves the visible rows.
- Tap calls `revealLine` and returns focus to the editor. The panel stays open.
- Empty outline shows a muted "No headings" label under the rule.
- Arrow keys are left to the focus system, as in the sidebar tree.
- `setSnapshot` diffs by item identity so an unchanged outline with a moved caret only updates the selection.
- The tab band is cut out over the panel the way it is over the Library (owner decision 2026-09-05): on iPad and Mac full screen the header band's mask gets a trailing hole from the panel's leading edge to the band's trailing edge, and the chip strip stops at the panel; on Mac windowed the AppKit titlebar band subtracts the same rectangle (`TitlebarBandGeometry.paint(..., outlineWidth:)`, posted with the divider as `outlineWidth`) and the chip strip's width stops at the panel.
- The layout oracle reports the trailing hole as `ChromeLayout.bandPaintTrailingHole`; the rule `outlinePanelIsNeverPaintedOver` mirrors `libraryIsNeverPaintedOver`.
- The container announces every panel frame change (`onOutlinePanelLayoutChanged`, also from its layout pass), so a window resize re-cuts the hole.

## 4. Shortcuts and persistence

⌘K reaches `RootSplitViewController.cmdToggleOutlinePanel()` through the same four lanes ⌘P uses:

1. Menu item "Outline Panel" in the View group of `AppDelegate.buildMenu`.
2. Scene-level `keyCommands` entry with `wantsPriorityOverSystemBehavior = true`.
3. `WebEditorSurface.shellAction` fallback case `("k", false)`.
4. `native-host.ts` capture-phase keydown forwards `{type: 'command', name: 'toggle-outline-panel'}`.

`admitShellAction` dedupes the lanes with the same 0.3s window the palette uses.
The AppKit glue does not need to swallow ⌘K; it has no system meaning on Catalyst.

Persistence:

- `WindowSession` gains `isOutlineVisible: Bool`, decoded with a default of `false` so records written before this change restore.
- `Preferences.outlinePanelWidth` beside `sidebarWidth`, same clamp on read and write.

## 5. Testing

ChalkKit (`swift test`, no simulator):

- `OutlineSnapshot` decodes the pushed `outline` body, including unknown kinds dropped.
- `UIState` id round-trip with the new axis; matrix count is 64.
- `WindowSession` decodes a record without `isOutlineVisible`.
- New invariants: each is falsifiable on a hand-built layout and passes on a correct one.

ChalkTests:

- `ChromeInvariantMatrixTests` and `ChromeTransitionMatrixTests` over every cell.
- `OutlinePanelToggleTests` mirroring `OutlineToggleTests`: open, close, zen refusal, dedupe.
- `ShellOutlinePanelKeyCommandTests` mirroring `ShellOutlineKeyCommandTests` for the four lanes.
- Subscription handoff on tab switch and on close.
- Restore with and without the session field.
- Push versus overlay at the width threshold.
- Resize clamps to the range and persists.

editor-core (`pnpm test`):

- `setOutlineSubscription(false)` installs no listener; a doc change produces no callback.
- Subscribed: a doc change and a selection change each produce one debounced callback with the expected shape.
- Unsubscribing cancels a pending debounce.

Manual: iPad simulator and Catalyst screenshots of push mode, overlay mode, both panels open, and zen, per `docs/ui-correctness.md`.

## Files touched

- `packages/editor-core/src/mount.ts`, `packages/editor-core/test/outline-subscription.test.ts`
- `web/src/native-host.ts`
- `mac/ChalkKit/Sources/ChalkKit/{ChromeLayout,ChromeInvariants,UIState,WindowSession}.swift`
- `mac/Chalk/Editor/{EditorSurface,WebEditorSurface,EditorContainerViewController}.swift`
- `mac/Chalk/Features/{OutlinePanelViewController,OutlineRowCell,OutlinePaletteViewController}.swift`
- `mac/Chalk/App/{RootSplitViewController,AppDelegate,ChalkMetrics}.swift`
- `mac/Chalk/Settings/Preferences.swift`
- `mac/ChalkTests/*` new suites listed above, `mac/ChalkTests/ChromeMatrixHost.swift`
- `docs/ui-invariants.md` (generated)
