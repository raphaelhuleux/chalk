import XCTest
import ChalkKit
@testable import Chalk

/// Shell wiring for the outline palette on a live RootSplitViewController:
/// Cmd+; toggles the overlay, and the two palettes are mutually exclusive.
/// Runs app-hosted (EditingModeTests pattern).
@MainActor
final class OutlineToggleTests: XCTestCase {
    private func makeRoot() -> RootSplitViewController {
        let root = RootSplitViewController()
        root.loadViewIfNeeded()
        root.view.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        root.view.layoutIfNeeded()
        return root
    }

    /// `admitShellAction` coalesces same-selector dispatches inside a 0.3s
    /// window (one key press arrives over several paths); a deliberate second
    /// toggle in a test must sit outside it.
    private func outlastAdmitWindow() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
    }

    func testCmdToggleOutlineShowsThenHides() {
        let root = makeRoot()
        XCTAssertFalse(root.isOutlineVisibleForTesting)

        root.cmdToggleOutline()
        XCTAssertTrue(root.isOutlineVisibleForTesting)

        outlastAdmitWindow()
        root.cmdToggleOutline()
        XCTAssertFalse(root.isOutlineVisibleForTesting)
    }

    func testRapidSecondToggleIsCoalescedAsGhostDuplicate() {
        let root = makeRoot()
        root.cmdToggleOutline()
        // Same press arriving via menu + pressesBegan + JS forward: the
        // duplicates land within the window and must NOT close the palette.
        root.cmdToggleOutline()
        XCTAssertTrue(root.isOutlineVisibleForTesting)
    }

    func testPalettesAreMutuallyExclusive() {
        let root = makeRoot()
        root.cmdQuickOpen()
        XCTAssertTrue(root.isQuickOpenVisibleForTesting)

        root.cmdToggleOutline()
        XCTAssertTrue(root.isOutlineVisibleForTesting)
        XCTAssertFalse(root.isQuickOpenVisibleForTesting)

        outlastAdmitWindow()
        root.cmdQuickOpen()
        XCTAssertTrue(root.isQuickOpenVisibleForTesting)
        XCTAssertFalse(root.isOutlineVisibleForTesting)
    }

    /// The outline snapshot is per-document: switching the active tab while
    /// the palette is open must hide it (Enter would otherwise jump the new
    /// tab to the old document's line numbers). Same-tab callbacks (dirty
    /// state, reorder) must NOT dismiss.
    func testActiveTabChangeHidesPaletteButSameTabCallbacksDoNot() {
        let root = makeRoot()
        let a = UUID(), b = UUID()
        root.simulateTabsChangedForTesting([
            TabItem(id: a, name: "a.md", isDirty: false, isActive: true, isPreview: false),
            TabItem(id: b, name: "b.md", isDirty: false, isActive: false, isPreview: false),
        ])
        root.cmdToggleOutline()
        XCTAssertTrue(root.isOutlineVisibleForTesting)

        // Dirty-state-only update: active tab unchanged, palette stays.
        root.simulateTabsChangedForTesting([
            TabItem(id: a, name: "a.md", isDirty: true, isActive: true, isPreview: false),
            TabItem(id: b, name: "b.md", isDirty: false, isActive: false, isPreview: false),
        ])
        XCTAssertTrue(root.isOutlineVisibleForTesting)

        // Active tab switches to b: the snapshot no longer matches — hide.
        root.simulateTabsChangedForTesting([
            TabItem(id: a, name: "a.md", isDirty: true, isActive: false, isPreview: false),
            TabItem(id: b, name: "b.md", isDirty: false, isActive: true, isPreview: false),
        ])
        XCTAssertFalse(root.isOutlineVisibleForTesting)
    }

    func testOpenWithNoTabsShowsEmptyStateAfterFetch() {
        let root = makeRoot()
        root.cmdToggleOutline()
        // fetchActiveOutline completes async (no tab → nil → .empty snapshot).
        let deadline = Date(timeIntervalSinceNow: 1.0)
        while !root.outlinePaletteVCForTesting.isEmptyStateVisibleForTesting,
              Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertTrue(root.outlinePaletteVCForTesting.isEmptyStateVisibleForTesting)
    }
}
