import XCTest
import ChalkKit
@testable import ChalkMac

/// Shell wiring for the persistent outline panel: ⌘K toggles it, one press
/// over several lanes toggles once, and zen owns it the way zen owns the
/// Library.
@MainActor
final class OutlinePanelToggleTests: XCTestCase {
    private var previousMode: EditingMode!
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        previousMode = Preferences.editingMode
        Preferences.editingMode = .normal
    }

    override func tearDown() {
        Preferences.editingMode = previousMode
        for window in windows { dismantleHostedSidebar(window) }
        windows = []
        super.tearDown()
    }

    private func makeRoot() -> (NSWindow, RootSplitViewController) {
        let window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1180, height: 820))
        let root = RootSplitViewController()
        root.motionPolicyForTesting = .instant
        window.rootViewController = root
        window.isHidden = false
        root.loadViewIfNeeded()
        root.view.layoutSubtreeIfNeeded()
        windows.append(window)
        return (window, root)
    }

    private func outlastAdmitWindow() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
    }

    func testCmdToggleOutlinePanelShowsThenHides() {
        let (_, root) = makeRoot()
        XCTAssertFalse(root.isOutlinePanelVisibleForTesting)
        root.cmdToggleOutlinePanel()
        XCTAssertTrue(root.isOutlinePanelVisibleForTesting)
        outlastAdmitWindow()
        root.cmdToggleOutlinePanel()
        XCTAssertFalse(root.isOutlinePanelVisibleForTesting)
    }

    func testRapidSecondToggleIsCoalescedAsGhostDuplicate() {
        let (_, root) = makeRoot()
        root.cmdToggleOutlinePanel()
        root.cmdToggleOutlinePanel()
        XCTAssertTrue(root.isOutlinePanelVisibleForTesting)
    }

    func testZenRefusesToOpenThePanel() {
        let (_, root) = makeRoot()
        root.setEditingMode(.zen)
        root.cmdToggleOutlinePanel()
        XCTAssertFalse(root.isOutlinePanelVisibleForTesting)
    }

    func testEnteringZenClosesThePanelAndLeavingDoesNotReopenIt() {
        let (_, root) = makeRoot()
        root.cmdToggleOutlinePanel()
        XCTAssertTrue(root.isOutlinePanelVisibleForTesting)
        root.setEditingMode(.zen)
        XCTAssertFalse(root.isOutlinePanelVisibleForTesting)
        root.setEditingMode(.normal)
        XCTAssertFalse(root.isOutlinePanelVisibleForTesting)
    }

    func testPanelAndPaletteAreIndependent() {
        let (_, root) = makeRoot()
        root.cmdToggleOutlinePanel()
        root.cmdToggleOutline()
        XCTAssertTrue(root.isOutlinePanelVisibleForTesting)
        XCTAssertTrue(root.isOutlineVisibleForTesting)
    }

    func testWebForwardedCommandTogglesThePanel() {
        let (_, root) = makeRoot()
        root.simulateShellCommandForTesting(ShellCommand.toggleOutlinePanel.rawValue)
        XCTAssertTrue(root.isOutlinePanelVisibleForTesting)
    }

    /// The band is cut out over the panel the way it is over the Library, so
    /// the panel reaches the window's top with its header in the band. The
    /// hole starts at the panel's leading edge and runs to the band's
    /// trailing edge; it goes away with the panel.
    func testOpeningThePanelCutsItOutOfTheBand() throws {
        let (_, root) = makeRoot()
        XCTAssertNil(root.bandTrailingHoleForTesting)
        root.cmdToggleOutlinePanel()
        root.view.layoutSubtreeIfNeeded()
        let hole = try XCTUnwrap(root.bandTrailingHoleForTesting)
        let panel = try XCTUnwrap(root.editorForTesting.outlinePanelFrame
            .map { root.view.convert($0, from: root.editorForTesting.view) })
        XCTAssertEqual(hole.minX, panel.minX, accuracy: 1)
        XCTAssertEqual(hole.maxX, root.view.bounds.maxX, accuracy: 1)
        outlastAdmitWindow()
        root.cmdToggleOutlinePanel()
        root.view.layoutSubtreeIfNeeded()
        XCTAssertNil(root.bandTrailingHoleForTesting)
    }
}
