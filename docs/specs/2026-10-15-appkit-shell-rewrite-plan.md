# AppKit shell rewrite

Plan for replacing the Mac Catalyst shell in `mac/Chalk` with an AppKit shell.
Same engine, same features, same look.
Written 2026-10-15, before any code.

## Goal and non-goals

The goal is a Mac app whose chrome is AppKit, drawn at native resolution, with no UIKit, no `ChalkAppKitGlue` plugin and no notification bridge between two toolkits.
Every feature the Catalyst app has today ships in the new shell.
The UI stays the Paper design at the same metrics, so a user who updates sees the same app with crisper chrome.

Non-goals:

- No change to `packages/editor-core`, `web/`, the `HostPort` protocol or the native transport messages.
- No redesign.
  A visual change needs its own spec and lands before or after this work, never inside it.
- No new features during the port.
  A missing feature is a parity bug.

## What does not change

- The engine and the web bundle.
  `web/build.mjs` keeps producing `Resources/editor`, and the Xcode pre-build phase stays as it is.
- ChalkKit, all of it.
  It is pure Foundation, and the policies the shell needs are already there: `WindowRouting`, `TabStripBridge` metrics and colours, `TabStripFit`, `TitlebarBandGeometry`, `ChromeInvariants`, `ChromeLayout`, `UIState`, `ChromeAutoHidePolicy`, `StripPresentationPolicy`, `SceneLaunchPolicy`, `RecoveryStore`, `BookmarkStore`, `WindowLocations`, `WindowSession`, `FileTree`, `FileWatcher`, `FuzzyMatcher`, `OutlinePalettePolicy`, `SidebarDropPolicy`, `CoordinatedFileMove`, `ShortcutTableModel`, `UserSnippetStore`, `SnippetComposer`, `BugReport`, `LaunchIntegrity`, `CrashPromptPolicy`, `DiagnosticsRing`, `DraftNaming`, `FileNaming`, `ExternalOpenRouting`.
- Persistence.
  The `chalk.*` preference keys, the bookmark stores, `WindowSession` encoding, the Recovery and ConflictCopies folders under Application Support, and the bundle ID `com.huleux.chalk`.
  An upgrade keeps settings, Library folders and unsaved snapshots.
  One exception: `chalk.sidebarWidth` and `chalk.outlinePanelWidth` are stored in Catalyst's iPad-idiom points (1/0.77 of a Mac point). The AppKit shell converts them once, in the Library phase, and the two accessors live in each shell rather than in ChalkKit.
- The sandbox entitlements and the UTIs in `project.yml`.
- The `EditorSurface` seam, with `view` retyped to `NSView`.
  `FakeEditorSurface` in the tests keeps working.

## Architecture of the new shell

One `NSWindowController` per editor window, an app-level registry of windows, and no scenes.
The table maps each Catalyst piece to its replacement.

| Catalyst piece | AppKit replacement |
| --- | --- |
| `AppDelegate` + `SceneDelegate` + `UIWindowScene` | `NSApplicationDelegate` plus `EditorWindowController: NSWindowController`; a `WindowRegistry` replaces `everyLiveRoot()` |
| `SettingsSceneDelegate` | `SettingsWindowController`, one per app, frame autosaved by `NSWindow.setFrameAutosaveName` |
| `DeclinedSceneDelegate`, ghost-scene sweep, bind tokens | deleted; AppKit has no scene sessions to reconnect |
| `RootSplitViewController: UISplitViewController` | `RootSplitViewController: NSSplitViewController`, two items, collapse driven by Chalk so the slide keeps its clock |
| `ChalkAppKitGlue` + `MacStripBridge` + `HeaderTabStrip` + `HeaderBarView` + `ChalkTitlebarBand` | one `TabStripView: NSView`, in process, pinned to the top of a `fullSizeContentView` window; the same view serves windowed and full screen |
| `FooterBarView` (utility pill) | `UtilityPillView: NSView` on an `NSVisualEffectView` |
| `ChalkGlassView` | `GlassView: NSView` wrapping `NSVisualEffectView`, same `Style` tokens, Reduce Transparency honoured through `NSWorkspace.accessibilityDisplayShouldReduceTransparency` |
| `SidebarViewController` on `UICollectionView` list | `SidebarViewController` on a view-based `NSOutlineView`, `selectionHighlightStyle = .none`, Paper row views |
| `SidebarRenameEditor` | in-row `NSTextField` editing, same `FileNaming` and case-only rename rules |
| `UIContextMenuInteraction` | `NSMenu` from `menu(for:)` on the outline view |
| `UIDragInteraction` / `UIDropInteraction` / collection drag delegates | `NSOutlineViewDataSource` pasteboard dragging; `TabStripView` as `NSDraggingSource` and `NSDraggingDestination`; decisions stay in `SidebarDropPolicy` |
| `UIDocumentPickerViewController` | `NSOpenPanel` with `canChooseDirectories` for Add Folder and Grant Access, `NSSavePanel` for naming a draft |
| `UIAlertController` | `NSAlert` as a window sheet |
| `PaletteOverlayHost`, `QuickOpenViewController`, `OutlinePaletteViewController` | the same in-window overlay, `NSTextField` plus `NSTableView`, key handling in `keyDown` and `control(_:textView:doCommandBy:)` |
| `OutlinePanelViewController` | `NSViewController` with `NSTableView`, same push and overlay modes |
| `AssetPreviewViewController` | `NSImageView` and `PDFView` in a sheet; `QLPreviewView` is in-process on AppKit and is the fallback if PDFKit is not enough |
| `UIMenuBuilder` | the main menu built in code in `AppDelegate`, `NSMenuItemValidation` for enablement and checkmarks |
| `UIKeyCommand` on views | menu key equivalents for shell commands, `keyDown` on the owning view for in-view keys (F2, arrows) |
| `UIHoverGestureRecognizer` and the glue's pointer lane | `NSTrackingArea` on the strip and the pill |
| `NSUserActivity` restoration | `NSWindowRestoration`: the window encodes `WindowSession` in `encodeRestorableState`, `restoreWindow(withIdentifier:state:)` rebuilds it |
| `UIDocument` (`ChalkDocument`) | a small `NSFilePresenter` class plus `NSFileCoordinator` reads and writes and `NSFileVersion` conflicts, which is what `UIDocument` wrapped; `DocumentController` keeps its API |
| `UIPasteboard` | `NSPasteboard` |
| `UITraitCollection`, `UIUserInterfaceStyle` | `NSAppearance` on each window, `effectiveAppearance` observed with KVO |
| `UIColor` dynamic providers in `ChalkPalette` | `NSColor(name:dynamicProvider:)` |
| `ChalkMetrics.s()` | deleted; every token is its spec value in Mac points |
| `WebPaintGate` | unchanged logic, `NSView` cover, `takeSnapshot` on the AppKit `WKWebView` |

### Decisions

1. **A second target during the port, not a branch.**
   `project.yml` gains a `ChalkMac` application target with `platform: macOS`, sharing ChalkKit, `Resources/editor`, the fonts and the UTIs.
   The Catalyst target keeps shipping until parity.
   At cutover `ChalkMac` takes the name, bundle ID and scheme, and the Catalyst target, the glue bundle and the bridge are deleted.
   Engine work continues on `main` throughout.

2. **No `NSDocument` for the tab model.**
   A Chalk window holds many files and `NSDocument` wants one document per window controller.
   Bending it costs more than it gives.
   `NSDocumentController.shared.noteNewRecentDocumentURL` provides Open Recent and `NSWindow.representedURL` provides the proxy icon without adopting the class.
   Revisit only after cutover, as its own spec.

3. **Chalk tabs, not `NSWindow` tabs.**
   Same reason: window tabbing is one window per tab, which is not the product.

4. **The tab strip is a content view, not an `NSToolbar` item.**
   The window uses `titleVisibility = .hidden`, `titlebarAppearsTransparent = true` and `.fullSizeContentView`.
   `TabStripView` is pinned to the top of the content view, insets past the traffic lights by `TabStripMetrics.trafficLightGap` while windowed and to the leading edge in full screen.
   `mouseDownCanMoveWindow` on its empty area keeps the titlebar draggable.
   This gives one tab row for both window modes and closes the gap the invariant doc names: the windowed row's pixels become assertable.
   An `NSToolbar` would keep the system drag behaviour for free but reintroduces a second layout owner over the same pixels, which is what the glue was fighting.
   Decided 2026-10-15: content view.

5. **All geometry in Mac points.**
   `ChalkMetrics` keeps its names and loses `s()`.
   `ChalkKit.TabStripMetrics` is already in Mac points.
   `editorRestingPad` stays in CSS px as today.

6. **Testing seams keep their names.**
   Every `*ForTesting` accessor on the root, the container, the sidebar and the strip is kept with the same name and type where the type is not UIKit, so the test port is mechanical.

7. **AppKit for Settings too.**
   SwiftUI would be less code for the General pane, but its layout cannot be asserted the way `SettingsRailTests` and `SettingsEditorRowLayoutTests` assert today, and the pane must match the current look.

## Feature parity checklist

Every line is a feature the Catalyst shell has today.
Each one is done when the named test is green on the AppKit target or, where no test exists, when the manual script in the cutover section passes.
Tests named here are the current `ChalkTests` files to port; a line without one gets a new test.

### Application and windows

- Multiple editor windows, New Window on Shift Cmd N, each with its own Locations (`WindowLocations` keyed by a stable window identifier that survives restoration). `CrossWindowSyncTests`, `WindowRoutingTests`.
- Window restoration: tabs with security-scoped bookmarks, active index, sidebar visible, outline panel visible, window frame; unreadable files dropped silently; bulk restore boots only the active surface. `SceneRoutingTests` becomes `WindowRestorationTests`.
- `CHALK_DISABLE_RESTORATION` and `CHALK_AUDIT_STATE` cold starts (Debug). `AuditMode` ports; `scripts/screenshots/capture-mac.sh` keeps working.
- First launch opens Welcome from `SampleContent` in a window with no Locations.
- Files and folders from Finder, `open -a Chalk`, Open With, and drops on the Dock icon route through `ExternalOpenRouting` to the right window or a new one. `AssetPreviewRoutingTests`, `ExternalOpenRouter` tests.
- Window minimum size `ChalkMetrics.minWindowSize`; Settings window floor `settingsMinWindowSize`, resizable, frame remembered.
- Resign-active saves every dirty document and an orderly quit marks a clean exit; the crash marker (`AlphaSession`, `LaunchIntegrity`) and the crash banner rules in `NoticeBannerView` (no first responder, equal-weight buttons, no deferral, answer exactly once). `AlphaSessionTests`, `NoticeBannerTests`, `BuildInfoTests`.
- Recovery: dirty buffers snapshot on a timer to `RecoveryStore.appDirectory`; on launch each window layers records matching its own restored tabs, and the leftover drain runs once per process. `DocumentControllerRecoveryTests`, `EditorContainerRecoveryDrainTests`, `DocumentControllerBufferProvenanceTests`.
- Logging under subsystem `com.huleux.chalk`, categories kept, `SceneStateLineRedactionTests` becomes the window-state line test.
- Debug builds keep bundle ID `com.huleux.chalk.debug` so tests never touch the installed app's defaults. `PreferencePollutionGuardTests`, `CrossWindowPreferenceTests`.

### Menu bar

The exact menu from `AppDelegate.buildMenu(with:)`, rebuilt as `NSMenu`:

- App menu: Settings on Cmd Comma at the top. No Spelling submenu.
- File: New Window (Shift Cmd N); New (Cmd N), Quick Open (Cmd O), Add Folder to Window (Shift Cmd O); Save (Cmd S), Close Tab (Cmd W). No system Duplicate, Move, Rename or Export items.
- View: Toggle Sidebar (Cmd J), Outline (Cmd P), Outline Panel (Cmd K), Editing Mode submenu (Normal, Zen, Typewriter, Focus, Cycle on Shift Cmd M, active item checked), View Mode submenu (Preview, Mixed, Source, current default checked), Zoom In (Cmd =), Zoom Out (Cmd -), Actual Size (Cmd 0), Next Tab (Control Tab), Previous Tab (Control Shift Tab). No Show/Hide Sidebar system item, no Toolbar item.
- No Format menu. Cmd B stays free for the editor.
- Help: Report a Problem, Privacy. `HelpMenuTests`.
- Shell commands act on the key window. `target(forAction:)` redirection and `admitShellAction` deduping go away, replaced by the responder chain and a test that a menu action reaches the key window's root only. `ShellShortcutTableTests`.
- New Window stays enabled with no windows open: the action lives on the app delegate.

### Tabs

- Strip in the titlebar, IBM Plex Mono names, active name heavier with the accent underline, inactive muted, synthetic oblique for the preview tab from `TabStripMetrics.obliqueSlant`. `TabLabelFontTests`, `TabNameRowTests`, `ThemePaletteTests`.
- Underline slides on a switch over `motionFast` and stays still on any other rebuild. `TabNameRowTests`.
- Hover swaps the dirty dot and the close glyph over `motionTab`; middle click closes; the plus button makes a new file. `TabMiddleClickTests`, `NewTabGlyphSizeTests`, `TabClickJitterTests` (kept as a one-click regression test).
- Drag to reorder per `docs/specs/2026-07-23-tab-drag-reorder-design.md`, with `TabStripFit` deciding widths. `TabReorderTests`, `TabStripFitTests` in ChalkKit.
- Overflow scrolls with an edge fade; names truncate, never overflow (the 80-character audit fixture).
- Leading inset follows the Library divider live, animates on the slide's clock, instant on drag deltas and on replay. `SidebarSlideContractTests`, `MacStripBridgeTests` (reduced to the inset rule, no bridge).
- Hidden in zen; auto-hides on scroll and returns on hover or on any explicit chrome action. `ChromeAutoHideTests`, `StripPresentationPolicy` tests.
- Close with unsaved edits asks Save, Discard, Cancel.
- Next and Previous Tab wrap. Switch cross-fades surfaces over `motionFast`, both hosted during the fade, exactly one after; incoming surface dressed with theme and chrome inset before install. `TabSwitchContractTests`, `EditorSurfaceInstallTests`.
- Explicit Cmd S pins a browse tab; automatic saves do not. `TabPinOnSaveTests`.
- Background tabs stay dormant until first shown. `WebEditorSurfaceFirstPaintTests`.

### Library sidebar

- Paper flat panel edge to edge, width persisted in 220 to 560 and only at rest, never mid-slide. `SidebarPanelAlignmentTests`, `SidebarRowMetricsTests`, `SidebarSafeAreaGeometryTests`.
- One area per Location with a header showing name, count and fold chevron; header menu with New File, New Folder, Grant Access when `needsReauthorization`, Remove from Window. `SidebarAreaHeaderTests`, `SidebarFolderToggleTests`.
- Row context menu: Open, Open in New Tab, Open in New Window, Preview for assets, New File, New Folder, Rename, Duplicate, Copy, Copy Path, Move to Trash. `SidebarContextMenuTests`, `docs/specs/2026-08-02-sidebar-rename-and-context-menu-design.md`.
- Tree with lazy children and grandchild prefetch, expansion state per node, fold keys on left and right arrow, F2 renames. `SidebarKeyboardNavTests`, `SidebarFolderToggleTests`.
- Inline rename including case-only renames; failures shown in place. `SidebarInlineRenameTests`, `CaseOnlyRenameTests`.
- Move to Trash with undo through `CoordinatedFileMove`; Duplicate, Copy Path. `SidebarFileOperationsTests`, including `testUndoRestoresATrashedFile`, which fails on Catalyst (`docs/known-failing-tests.md`) and passes on the AppKit port as written: `FileManager.trashItem` hands back the trashed item's URL there, which is what the undo moves back.
- Drag and drop moves within and across Locations, drop targets from `SidebarDropPolicy`, no drop into own subtree. `SidebarDropTargetTests`.
- Open-document highlight follows the active tab; a sidebar click browses in place unless the tab is pinned or dirty; Cmd click opens a new tab. `SidebarOpenTargetTests`, `LibraryListStartTests`.
- Asset rows (images, PDFs) open the preview sheet. `AssetPreviewRoutingTests`.
- Reload coalesced at 0.1 s off the file watcher, stale applies dropped, file work off the main thread. `SidebarReloadRaceTests`, `SidebarFileWorkThreadingTests`.
- Add Folder and Grant Access through `NSOpenPanel`; a failed add reports and leaves the store intact. `AddLocationFailureTests`, `LocationStoreTests`.
- Slide show and hide over `motionSidebar`: column translation, editor content translation, strip inset on the same clock, webview bounds frozen until the `WebPaintGate` settle. `SidebarSlideContractTests`, `ChromeTransitionMatrixTests`.
- Scopes released when the window closes. Tests on `LocationStore`.

### Editor column

- Empty state when no tab is open.
- Chrome top inset: the text rests one editor line below the band, scrolls under it, inset glided on transitions. `EditorSafeAreaTests`, `ZenTransitionContractTests`.
- Font scale, measure, line height, alignment and heading colours pushed to every tab and applied live from Settings. `EditorPreferencesTests`, `WebEditorSurfaceSettingsTests`, `MarkdownHeadingColorsTests`.
- Appearance flip under a covered reflow; Atom dark is the default theme; the forced Light or Dark preference overrides the system appearance on every window including Settings and sheets. `AppearanceTransitionContractTests`, `EditorLaunchAppearanceTests`, `HelpScreenPresentationTests`.
- Hsnips: the bundled `latex.hsnips` plus user snippets pushed to every surface, re-pushed on edit. `DocumentControllerHsnipsTests`.
- Outline panel on Cmd K: push mode when the column is wide enough, overlay otherwise; width persisted; header level with the traffic lights; selection follows the caret; click jumps and keeps the panel; footer prose counts; closed by zen. `OutlinePanelViewControllerTests`, `OutlinePanelLayoutTests`, `OutlinePanelToggleTests`, `OutlinePanelRestorationTests`, `OutlinePanelSubscriptionTests`, `WebEditorSurfaceOutlinePushTests`, `ShellOutlinePanelKeyCommandTests`.
- Editing modes Normal, Zen, Typewriter, Focus, picked from the pill menu or the View menu, cycled on Shift Cmd M. `EditingModeTests`, `ZenTransitionContractTests`.
- Default view mode Preview, Mixed, Source. `ViewModeTests`.
- Zoom in, out, reset in the editor font scale range.
- Scroll telemetry drives `ChromeAutoHidePolicy`; the preference flips live. `ChromeAutoHideTests`.
- Shell commands from the web layer (save, toggle-outline, toggle-outline-panel) reach the root. `ShellOutlineKeyCommandTests`.
- Surface failure after boot recovery shows Retry or Close Tab; an unreadable file shows an open failure; a failed write shows a save failure; a file changed outside reloads when clean and asks when dirty. `DocumentControllerExternalReloadTests`, `DocumentControllerReadyRaceTests`, `WebEditorSurfaceEpochTests`, `WebEditorSurfaceReplyTests`.
- Asset resolution, workspace file listing and `.bib` reads over the transport. `AssetResolveTests`.
- Links open in the default browser through `NSWorkspace`.
- WebKit's own selection highlight stays off. `NativeSelectionHighlightTests`, rewritten for the AppKit view tree and deleted if AppKit WebKit does not paint it.
- Copy and paste from the editor work. The `UIPasteboard` workaround in `EditorWebView` is dropped and a test confirms the AppKit `WKWebView` does not need it.
- Reduce Motion replaces slides with instant placement and keeps every cover.

### Palettes

- Quick Open on Cmd O: fuzzy match on `parent/name` across every Location, blank query lists the first fifty, index fills asynchronously, Return browses in place, Cmd Return opens a new tab, Escape and click outside dismiss, focus returns to the editor. `QuickOpenViewController` tests, `PaletteCenteringTests`, `PaletteStripScrimTests`.
- Outline palette on Cmd P: headings, numbered callouts and figures, cursor's section preselected, indentation flattens under a query, Return jumps. `OutlinePaletteTests`, `OutlineToggleTests`.
- Overlay: dim scrim, glass card hugging its content, capped against the window, reveal and hide animation, the editor blurred while open. `PaletteOverlayHost` tests.

### Settings, Help and About

- Settings in its own window: General pane with Appearance (Auto, Light, Dark), Theme menu over `ChalkTheme`, Auto-hide tabs; Editor section with text size, text width, line spacing sliders and readouts rewritten in place, Alignment, Color headings, New documents (Markdown, LaTeX), View mode; About with version, build and commit, Report a Problem, Privacy, Acknowledgements. `SettingsRailTests`, `SettingsEditorRowLayoutTests`, `AboutSectionTests`.
- LaTeX Shortcuts pane: category rail, search, add row under Yours, inline edit, built-ins fork into user snippets on first edit, Reset on a forked row (a context menu or row button replaces the swipe), options table per `docs/specs/2026-08-02-snippet-options-table-design.md`. `ShortcutsSettingsViewController` tests, `ShortcutTableModel` tests in ChalkKit.
- Changes apply live to every window through `SettingsBroadcast`; the Settings window re-pins its own appearance.
- Report a Problem: Bug or Feedback, notes, include diagnostics switch, live preview of the exact bytes, Send opens the GitHub new-issue page. `ReportProblemTests`.
- Privacy: the six sections, reveal Chalk's folder, empty the Recovery folder, counts read from disk.
- Acknowledgements from the generated third-party notices.
- Report a Problem and Privacy present as sheets with the forced appearance and return focus to the editor. `HelpScreenPresentationTests`.

### Documents

- Draft on New with `DraftNaming` and the default file type; first save names it through `NSSavePanel` with the type's extension; `bindDraft` keeps edits. `DraftSaveFileTypeTests`.
- Coordinated writes, one at a time, trailing saves coalesced; explicit versus automatic save distinguished. `DocumentControllerSaveConflictTests`, `DocumentControllerEditIngressTests`.
- Dirty state in `DocumentBuffer`, never in the file presenter. `DirtySpy`.
- UTF-8 refusal and directory refusal on open. `ChalkDocumentLoadTests`, `DocumentControllerDirectoryOpenTests`, `DocumentControllerLanguageTests`.
- External change detection through `FileWatcher` and the presenter; conflict versions resolved through `NSFileVersion` with the losing copy in ConflictCopies when the sandbox refuses the sibling. `DocumentControllerReopenSafetyTests`.
- Rename or move while open rebinds the tab. `handleFileMoved` tests.
- Security scopes: Finder-opened files hold their scope for the session, restored tabs re-enter it from the bookmark, scopes released on close.

### Chrome invariants and motion

- All nineteen rules in `ChromeInvariant.catalogue` hold across the 32-cell matrix. `ChromeInvariantMatrixTests`, `ChromeMatrixHost`, `TestWindow`.
- The transition matrix and every contract in `docs/motion.md`. `ChromeTransitionMatrixTests`, `ChromeLayoutReportingTests`, `ChromeControlsTests`, `FooterPillPlacementTests`, `RootInitOrderTests`, `ChalkGlassMaterialTests`, `PaperSurfaceTests`.
- Full screen: traffic lights gone, strip inset to the leading edge, band and pill ownership per `TabChromeOwnership`, the Library and outline panel geometry unchanged across a round trip (the 2026-08-18 sidebar gap and the 2026-08-17 fullscreen drop must not come back).

## UI parity method

Same look is checked, not eyeballed.

1. **Freeze the reference before writing code.**
   Run `ChromeInvariantMatrixTests` on the Catalyst build with a Debug-only dump of `chromeLayout(for:)` for all 32 states, divide every rect by `ChalkMetrics.displayScale`, and commit the result as `Tests/chrome-reference/catalyst-2026-10.json`.
   The pixel reference is the showcase set in `docs/images/`, retaken by `scripts/screenshots/capture-mac.sh`; one PNG per cell is not worth a new audit driver.
2. **Metrics come from the spec, not from the old code.**
   Every `ChalkMetrics` token is already documented with its spec value; drop `s()` and keep the number.
   Fonts: IBM Plex Mono at `TabStripMetrics.fontSize`, system font at 13 for rows and headers, 11 for counts.
3. **Compare layouts numerically.**
   A new test, `ChromeReferenceParityTests`, runs the matrix on the AppKit shell and asserts each rect within 1 pt of the reference, after the known deliberate differences are listed in the test with a reason each (the titlebar height differs between Catalyst and AppKit windows, so `restingLineSitsOneLineBelowTheReserve` is the rule to trust there, not the raw number).
4. **Compare pixels by eye once per phase.**
   The screenshot script retakes the showcase shots from the AppKit build and they sit beside the Catalyst ones in a review page under `docs/showcase/`.
5. **Colours from one source.**
   `ChalkTheme`, `ChromeScrim` and `ThemePalette` in ChalkKit are the only colour definitions; `ChalkPalette` becomes a thin `NSColor` adapter over them.

## Phases

Each phase ends with its tests green on the `ChalkMac` target and the Catalyst target untouched.
Phases 1 to 6 are sequential; the test port in each phase is part of the phase, not a later step.

### Phase 0: preparation

Done 2026-10-15 on branch `appkit-shell`: `ChalkMac` and `ChalkMacTests` targets, the shared code in ChalkKit (`Preferences`, `ChromeMetrics`, `BuildInfo`, `AlphaSession`, `Diagnostics`, `SnippetLibrary`, `LocationStore`, `RecoveryLocation`, `SampleContent`, the notification names), the reference in `Tests/chrome-reference/`, and the `build-mac-appkit` step. Catalyst: 502 tests green after the move.

- Add the `ChalkMac` target and a `ChalkMacTests` bundle to `project.yml`; bundle IDs `com.huleux.chalk.mac` and `.mac.debug` until cutover; entitlements file `Chalk-mac.entitlements` with the same three keys; Info.plist keys for `NSPrincipalClass`, the document types and UTIs copied.
- Move everything UIKit-free out of `mac/Chalk` into ChalkKit so both shells share it and `swift test` covers it: `ChalkMetrics` as numbers, `Preferences` minus `interfaceStyle`, `SampleContent`, `BuildInfo`, `AlphaSession`, `RecoveryLocation`, `Diagnostics`, `Tab`, `TabItem`, `SnippetLibrary`, `LocationStore`, `SidebarFileOperations` minus the alerts.
  This lands on the Catalyst app first and ships, which de-risks the move.
- Freeze the reference per the parity method.
- Add a `build-mac-appkit` step to `scripts/check.sh` that builds the new target with warnings as errors, so it never rots between phases.

Exit: Catalyst app unchanged in behaviour, ChalkKit tests cover the moved code, `ChalkMac` builds an empty window.

### Phase 1: window, surface, document

- `EditorWindowController`, the transparent-titlebar window, `NSAppearance` forcing from the theme preference.
- `WebEditorSurface` on the AppKit `WKWebView`: native transport unchanged, `takeSnapshot` for `WebPaintGate`, selection highlight check, clipboard check, sandboxed Release build loading `editor.html` through `loadFileURL`.
  The 2026-08-19 crash loop is retested here on day one.
- `ChalkDocument` as a file presenter; `DocumentController` ported with no API change.
- One tab, save, dirty, external reload, conflicts, recovery snapshots.

Exit: every `DocumentController*`, `WebEditorSurface*`, `ChalkDocumentLoadTests` and `DraftSaveFileTypeTests` green.

Done 2026-10-15. 95 tests green on `ChalkMacTests` (one skipped: the known reopen wedge, carried over as is). What the port taught:

- `@main` on the `NSApplicationDelegate` class never attached the delegate: the app sat in its run loop with no window and no breadcrumbs. The entry point is an explicit `main.swift` that creates the delegate and calls `NSApplicationMain`.
- Setting `contentViewController` resizes the window to the view's frame, so the opening size is set after it.
- `ChalkDocumentLoadTests` became `ChalkDocumentTests`: the directory and UTF-8 refusals now live in the read path, since there is no `load(fromContents:)`.
- `ShellShortcutTableTests` and the `pressesBegan` table are deleted, not ported. AppKit's menu bar handles the key equivalents, and the four keys the page consumes (`SHELL_COMMANDS` in native-host.ts) arrive only over the `command` message, so no keystroke reaches the shell twice and nothing needs deduping. The phase 6 keystroke test confirms this on a real window.
- `NativeSelectionHighlight` has no AppKit counterpart: WebKit on macOS paints the selection in the web process. Deleted with its test.
- The `UIPasteboard` copy workaround is dropped; copy and paste are checked by hand in phase 2 and by the cutover script.
- AppKit's `WKWebView` has no public opaque switch. The under-page colour is the editor background and the page's own `:root` paints the theme from the document-start seed; no private `drawsBackground` call.
- `DraftSaveFileTypeTests` waits for the editor container (phase 2).
- The sandbox risk is settled: the blank sandboxed editor reproduces on AppKit, and a minimal probe shows WKWebView's content process needs `com.apple.security.network.client` under the App Sandbox even for local files. Not a port concern; the decision is recorded in `docs/issues/2026-08-19-sandbox-crash-loops-the-webview.md`.

### Phase 2: tabs, container, pill, chrome

- `TabStripView` in the titlebar, both window modes.
- `EditorContainerViewController` with cross-fade, close confirm, empty state, chrome inset, zoom, hsnips, preferences push.
- Utility pill, glass view, editing modes, view mode default, auto-hide, hover tracking.

Exit: tab, chrome, auto-hide, editing mode and transition contract tests green, except the Library and outline cells.

Done 2026-10-15. 213 tests green on `ChalkMacTests`. What the port taught:

- The window carries an empty unified `NSToolbar` with no items: that is what gives the transparent titlebar its tall form with the traffic lights centred, while the band in the content view under it takes the clicks. `BandLayout.resolve` runs in its overlay branch (`glueAvailable: true`) with the titlebar height read live from `contentLayoutRect`; the band owns the tab row in both window modes, so `TabChromeOwnership` reduces to "zen stands down".
- A theme is not an `NSAppearance`, so `viewDidChangeEffectiveAppearance` never fires for it. `ChalkAppearance.theme` posts `themeDidChange` and every view that caches a resolved `CGColor` re-resolves on it; the tab names rebuild their attributed titles.
- The tab label is a custom view drawing the attributed string: an `NSTextField` adds 2 pt of cell padding on each side, which broke every gap and underline measurement by 4 pt.
- The oblique tab font goes through `CTFontCreateCopyWithAttributes` with a unit shear. `NSFont(descriptor:textTransform:)` reports a 1 pt font for the bundled face, and a descriptor `.matrix` beside a size does the same.
- A scroll view's document view needs its origin pinned to the clip view, or Auto Layout leaves its width ambiguous and low-resistance labels collapse to nothing.
- The zen chrome-top glide is armed before the Library and outline closes, because on AppKit those run a synchronous layout pass that would consume it.
- The column widths live under AppKit keys (`chalk.sidebarWidth.appkit`, `chalk.outlinePanelWidth.appkit`), converted once from the Catalyst values; the two shells never fight over one key during the dual-target period.
- `EditorSafeAreaTests` is replaced by `EditorColumnLayoutTests`: the horizontal safe-area carve was a macOS 27 Catalyst split-view behaviour. The two Catalyst-only strip tests and the Settings-row halves of two suites are left for their phases.
- `ChalkGlassView` takes `NSGlassEffectView` on macOS 26 and the blur before it, as the UIKit one did with `UIGlassEffect`.

### Phase 3: Library

- `NSOutlineView` sidebar, Locations, bookmarks, headers, menus, rename, file operations with undo, drag and drop, watcher reload, asset rows, open panels.
- The slide with the frozen webview and the strip inset on the same clock.

Exit: every `Sidebar*`, `Library*`, `LocationStore*`, `AddLocation*`, `CaseOnlyRename*` test green.

Done 2026-10-15. 357 tests green on `ChalkMacTests` (one skipped: the reopen wedge), including the ported invariant and transition matrices; Catalyst and ChalkKit untouched in count. What the port taught:

- The tree is an `NSOutlineView` over class-backed row items (`LibraryRowItem`, `LibraryLocationItem`): the table keys expansion and reloads on item identity, so a reload reconciles rows in place by `FileNode` and keeps the objects that survive. The model's `isExpanded` is the truth, mirrored from the table's expand and collapse notifications and re-applied when a collapsed parent opens again.
- AppKit refuses to collapse an item whose outline cell is hidden through `shouldShowOutlineCell`: `collapseItem` returns before asking the delegate. The disclosure triangle is removed by giving it a zero frame (`frameOfOutlineCell`) and the cell draws its own chevron.
- The table reads the data source back during its own row updates. The model is written first, in its final shape, through references; an inout borrow of `children` across `removeItems` is an exclusivity violation that kills the process.
- A hidden Library column keeps its width and the editor's leading pin swaps between the divider and the window edge. A zero-width column cannot satisfy the panel's own insets and Auto Layout breaks a constraint on every pass.
- `BandLayout` windowed rests the text below the band, not the raw titlebar: on AppKit the band is hosted windowed too, so a titlebar shorter than the row (the test window's standard one) floors the band and the text must clear it. The app's unified-toolbar titlebar is taller than the row, so it sees no change.
- The slide is two `CABasicAnimation`s on `transform.translation.x` (the column and the frozen content) under one `CATransaction` completion, epoch-guarded like the Catalyst one; the model transform lands at once so a reader sees the end state the same turn. The chips animate through their constraint inside an `NSAnimationContext` with implicit animation on.
- The Catalyst titlebar-band click replay is gone: the window hands clicks under the transparent titlebar to the content views, which `SidebarTitlebarClickTests` proves through the frame view's own hit-test, Library header, first row, band hole and tab strip.
- `trashItem` returns the trashed URL on this shell, so `testUndoRestoresATrashedFile` passes unchanged.
- Deferred to their phases: the asset preview sheet (phase 4; the routing and the row behaviour are in), the per-window `LocationStore` and the full menu (phase 6; `CHALK_DEBUG_LIBRARY` seeds a folder for screenshots meanwhile).

### Phase 4: palettes, outline panel, preview

- Overlay host, Quick Open, outline palette, outline panel in both modes, asset preview sheet.

Exit: `QuickOpen*`, `Outline*`, `Palette*`, `AssetPreview*` tests green.

Done 2026-10-15. 433 tests green on `ChalkMacTests` (one skipped). What the port taught:

- The palettes' keys are the main menu's key equivalents (⌘O, ⌘P, ⌘K), which AppKit routes to the root from any first responder, the search fields included; the Catalyst scene-level key commands and their shadowing hazard are gone, and `ShellKeyEquivalentTests` pins that no palette claims them.
- ⌘↩ never reaches the field editor's command path: it is a key equivalent, caught on the card's content view (`PaletteContentView`). Up, Down, Escape and Return arrive through `control(_:textView:doCommandBy:)` on one shared table (`PaletteFrame.command(for:)`).
- The overlay mounts on first present, after every other root view exists, so it stacks above the band; the scrim therefore dims the strip on its own and the Catalyst strip-scrim post has no AppKit counterpart.
- A click on the scrim dismisses; clicks inside the card's content do not, decided by the backdrop from the event's point rather than by gesture delegates.
- The asset preview is an `NSWindow` sheet with PDFKit or an `NSImageView` in a magnifying scroll view; Done and Escape end the sheet, and the sheet's completion returns focus to the editor.
- `CHALK_DEBUG_PALETTE=quick-open|outline|outline-panel` opens one at launch for screenshots, and the Library test seam also feeds `libraryRoots`, so Quick Open indexes the seeded folder.

### Phase 5: Settings, Help, crash banner

- Settings window with both panes, live broadcast, Report a Problem, Privacy, Acknowledgements, Help menu, crash banner and launch verdict.

Exit: `Settings*`, `Shortcut*`, `About*`, `ReportProblem*`, `HelpMenu*`, `HelpScreen*`, `NoticeBanner*`, `AlphaSession*` tests green.

Done 2026-10-15. 496 tests green on `ChalkMacTests` (one skipped). What the port taught:

- Settings is an `NSWindowController` the app delegate keeps, one per app: ⌘, focuses it, its frame is autosaved, and its window and any sheet on it carry `ThemePreference.appearance`, which the broadcast re-pins. Done, Esc and ⌘, from inside the window all close it; the container answers `cmdSettings` because the responder chain from the Settings window never reaches an editor root.
- The General pane is cards of `SettingsRowView` (title, detail, trailing control) rather than a table: the row layout tests assert on the same real frames, and an `NSSlider` needs an explicit width the way a `UISlider` did.
- The shortcuts table flattens its two sections into one `NSTableView` with automatic row heights; the replacement is a wrapping `NSTextField`, so Return commits and Option-Return inserts a newline. Reset and Delete are a row button and a context menu, replacing the swipe. `SnippetLibrary` takes its store at init so the pane can be tested over a throwaway defaults suite.
- Report a Problem and Privacy are `HelpSheet` sheets on whichever window asked (editor or Settings), the screen over a Done bar, with Esc as Done; the sheet's completion is where focus returns to the editor.
- The crash banner is the same view with the same rules, on AppKit's terms: `acceptsFirstResponder` false, `refusesFirstResponder` on every button, and a hit test that returns nil for anything but a button. An image-only `NSButton` carries the title "Button" until told otherwise, which the equal-weight test caught.
- `AlphaSession` is read in `applicationWillFinishLaunching`, marked foreground on `applicationDidBecomeActive`, clean on `applicationWillTerminate`, and the first window asks for the crash prompt a second after it opens.
- Not ported: `ShellShortcutTableTests`, which pins the Catalyst webview's `pressesBegan` table; on AppKit the menu's key equivalents are the one table (`ShellKeyEquivalentTests`).
- `CHALK_DEBUG_PALETTE=settings|settings-shortcuts` opens the window on either pane for screenshots.

### Phase 6: menu bar, multi-window, restoration, external open

- The full menu with validation, window registry, per-window Locations, restoration through `NSWindowRestoration`, external open routing, resign-active saves, orderly quit, logging lines.

Exit: `CrossWindow*`, `WindowRouting*`, the restoration tests, `ShellShortcutTable*`, `SceneStateLineRedaction*` green; the manual multi-window script passes.

### Phase 7: the matrix and the rest

- `ChromeMatrixHost` and `TestWindow` on `NSWindow`; the 32-cell matrix green with the blind-cell guard passing; `ChromeReferenceParityTests` green.
- Every remaining `ChalkTests` file ported or deleted with a line in the commit saying why.
- `scripts/check.sh`: `build-mac`, `ui-invariants`, `mac-tests`, `pref-guard` point at `platform=macOS`; the failure extractor is unchanged because `xcodebuild` output is.
- `scripts/install-mac.sh`, `scripts/release-mac.sh`, `scripts/screenshots/capture-mac.sh`: product path `Build/Products/Release/Chalk.app` instead of `Release-maccatalyst`; re-verify the three signing rules in `install-mac.sh` on the AppKit bundle, since the "never sign with entitlements" rule was learned on a Catalyst bundle.
- Docs: `CLAUDE.md`, `docs/ui-correctness.md` (the 77% trap paragraph goes, the "relationships not absolutes" rule stays), `docs/ui-invariants.md` regenerated with the coverage table re-read from a run, `docs/release-steps.md`, `docs/known-failing-tests.md`.

Exit: `./scripts/check.sh` green with the AppKit target in every Xcode step.

### Phase 8: cutover

- The owner uses the AppKit build daily for as long as they want before release, installed through `install-mac.sh`, with the Catalyst app kept as `Chalk.app.prev`. No tester build.
- Bundle IDs swap to `com.huleux.chalk` and `.debug`; settings, bookmarks and recovery carry over because keys and folders did not change; a fresh install and an upgrade from the Catalyst build are both tested.
- Delete `mac/ChalkAppKitGlue`, `MacStripBridge.swift`, `HeaderTabStrip.swift`, `HeaderBarView.swift`, the scene delegates, `ChalkMetrics.s`, the Catalyst target and the `Chalk-macCatalyst.entitlements` file.
  Delete ChalkKit code that only served the bridge: `TabStripBridge` notification names and keys, `TitlebarAttachPolicy`, `WindowRouting` bind-token lanes, `SceneLaunchPolicy`.
  Keep `TabStripMetrics`, `TabStripFit`, `TitlebarBandGeometry`, `StripPresentationPolicy`.
- README screenshots retaken.

## Test strategy

The 100 files and 502 tests in `ChalkTests` split three ways.

- **Move to ChalkKit.** Logic tests that only touched UIKit for a type: run under `swift test` after phase 0.
- **Port.** Hosted tests that build a root in a window and read frames or state through the `*ForTesting` seams. Most files. `UIView` becomes `NSView`, `CGRect` conversions use `convert(_:to:)` on the window's content view, flipped coordinates handled once in `ChromeMatrixHost`.
- **Delete.** Tests that pin Catalyst-only machinery: bind tokens, glue availability, scene ghost sweeps, the titlebar band click replay, the UIKit-row versus AppKit-row ownership split, the shell-action double-fire dedupe. Each deletion names the reason in the commit.

Traps to write down before the first hosted test:

- `NSApplication.shared` must exist and have `.accessory` activation policy in the test bootstrap, or windows do not lay out and the Dock shows a test icon.
- Call `window.layoutIfNeeded()` and read `frame` in the content view's coordinates, never `bounds` of a flipped view against an unflipped one.
- Full screen cannot be entered in a test. Keep a `setMacFullscreenForTesting` that drives the same code path the `willEnterFullScreen` notifications drive, as today.
- An `NSOutlineView` reloads asynchronously after `reloadData` only if animated; use the non-animated path in tests, as the sidebar already does.
- The persisted-preference and unhosted-root traps in `docs/ui-correctness.md` still apply verbatim.

New tests the port adds: `ChromeReferenceParityTests`, a clipboard round-trip through the AppKit web view, a menu-action-reaches-key-window test, a restoration round-trip through `NSWindowRestoration`.

## Build and release

- `project.yml`: `ChalkMac` target `platform: macOS`, `deploymentTarget: "14.0"`, same pre-build script, `ENABLE_USER_SCRIPT_SANDBOXING: false`, Automatic signing with no team, `CODE_SIGN_ENTITLEMENTS` pointing at the Mac entitlements. No `SUPPORTS_MACCATALYST`, no `TARGETED_DEVICE_FAMILY`.
- `ChalkMacTests` as `bundle.unit-test`, `platform: macOS`, depending on `ChalkMac`.
- The `Chalk` scheme stays the only scheme at cutover and points at the new targets.
- `release-mac.sh` loses the Catalyst destination; notarization is otherwise identical.

## Risks

- **Keyboard routing in the AppKit `WKWebView`.** Menu key equivalents run before the web view's `keyDown`, which is what the glue's Cmd P monitor emulated. The reverse risk is the menu eating an editor shortcut; the menu deliberately omits Cmd B and Cmd Colon today and must keep doing so. Decide per shortcut in phase 2 with a test that types into the web view and checks who handled it.
- **Sandbox and the file-URL load.** Settled in phase 1: not Catalyst-specific, and not code. See the phase 1 notes.
- **`NSOutlineView` and the Paper look.** Row height 30, no source-list tint, flat background and custom disclosure need a custom `NSTableRowView` and `outlineView(_:rowViewForItem:)`; budget a day.
- **Pasteboard drag types.** Sidebar drops carry file URLs; tab drags carry a private type. Both go through `NSPasteboardItem` and the decision code stays in ChalkKit.
- **Full screen is manual.** Every phase that touches the strip, the Library or the outline panel ends with the manual full-screen round trip from `docs/issues/2026-08-18-sidebar-gap-after-fullscreen.md`.
- **Time.** The shell is about 16k lines plus 100 test files. Expect weeks of focused work with the test port as the long pole. The second target keeps the Catalyst app shippable the whole time, so the cost is schedule, not risk to users.

## Manual script for cutover

Run on a fresh user account and on an account upgraded from the Catalyst build.

1. Launch. Welcome opens. Quit. Relaunch. Welcome does not reopen.
2. Add a folder. Open three files from the Library. Reorder tabs. Quit. Relaunch. Same tabs, same order, same active tab, same window frame, Library open.
3. Edit a file, Cmd S, edit again, Cmd W, Discard. Edit again, force quit, relaunch: the crash banner shows, the edit is recovered.
4. Full screen round trip with the Library open and the outline panel open. No gap, no dropped full screen, tabs in place.
5. Settings: flip appearance, theme, every slider, auto-hide, alignment. Every open window follows live.
6. Cmd O, Cmd P, Cmd K, Cmd J, Shift Cmd M through all four modes, Cmd Shift N, Open in New Window from the Library, drag a file from Finder onto the Dock icon.
7. Rename a file case-only, move it between Locations by drag, trash it, undo.
8. Report a Problem preview matches what the browser receives. Privacy reveals the folder and empties Recovery.
9. Copy and paste inside the editor and from the editor to another app.
10. Switch to the Catalyst build and back. Settings and Library folders are intact both ways.
