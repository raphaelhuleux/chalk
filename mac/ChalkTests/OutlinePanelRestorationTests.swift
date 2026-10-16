import XCTest
import ChalkKit
@testable import Chalk

/// The panel restores per window, like the Library.
@MainActor
final class OutlinePanelRestorationTests: XCTestCase {
    private static let widthKey = "chalk.outlinePanelWidth.appkit"
    private var savedWidth: Any?
    private var scratch: URL?
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        // A stale persisted width would move the push/overlay threshold under
        // the geometry assertions below (docs/ui-correctness.md: persisted
        // preferences are one of the ways this class of test goes vacuous).
        savedWidth = UserDefaults.standard.object(forKey: Self.widthKey)
        UserDefaults.standard.removeObject(forKey: Self.widthKey)
    }

    override func tearDown() {
        if let savedWidth {
            UserDefaults.standard.set(savedWidth, forKey: Self.widthKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.widthKey)
        }
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
        for window in windows { dismantleHostedSidebar(window) }
        windows = []
        super.tearDown()
    }

    /// 1180pt wide: the editor column can spare the panel's width, so a
    /// restored-open panel must land in PUSH mode. That makes the trailing-pin
    /// assertion falsifiable: an unlaid-out or parked panel reports "edge".
    private func hosted(_ root: RootSplitViewController) -> NSWindow {
        let window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1180, height: 820))
        root.motionPolicyForTesting = .instant
        window.rootViewController = root
        window.isHidden = false
        root.loadViewIfNeeded()
        root.view.layoutSubtreeIfNeeded()
        windows.append(window)
        return window
    }

    /// The panel is really on screen, not merely flagged open: a frame, a
    /// non-empty one flush with the column's trailing edge, and the content
    /// pushed off it.
    private func assertPanelIsRealized(
        _ root: RootSplitViewController, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let editor = root.editorForTesting
        editor.view.layoutSubtreeIfNeeded()
        let panel = try XCTUnwrap(editor.outlinePanelFrame,
                                  "restored panel has no frame", file: file, line: line)
        XCTAssertFalse(editor.outlinePanel.view.isHidden,
                       "restored panel is hidden", file: file, line: line)
        XCTAssertGreaterThan(panel.width, 0, file: file, line: line)
        XCTAssertEqual(panel.maxX, editor.view.bounds.maxX, accuracy: 1,
                       "restored panel is parked off the trailing edge", file: file, line: line)
        XCTAssertEqual(editor.activeContentTrailingPinForTesting, "panel",
                       "a 1180pt column must push, not overlay", file: file, line: line)
    }

    func testCaptureRecordsTheOpenPanel() throws {
        let root = RootSplitViewController(initialContent: .openEmpty)
        _ = hosted(root)
        root.cmdToggleOutlinePanel()
        let session = root.captureSession()
        XCTAssertTrue(session.isOutlineVisible)
        // The session round-trips as data, which is what restoration reads.
        let data = try XCTUnwrap(try? JSONEncoder().encode(session))
        XCTAssertEqual(WindowSession(data: data)?.isOutlineVisible, true)
    }

    func testRestoreReopensThePanel() throws {
        let session = WindowSession(tabs: [], activeIndex: nil, isSidebarVisible: false, isOutlineVisible: true)
        let root = RootSplitViewController(initialContent: .restoreSession(session))
        _ = hosted(root)
        XCTAssertTrue(root.isOutlinePanelVisibleForTesting)
        try assertPanelIsRealized(root)
    }

    /// Order independence: with tabs, `applyRestoredSession` opens documents
    /// (which loads the container's view, and with it the panel) BEFORE it
    /// restores the panel; the reverse of the empty-session order, where the
    /// panel call is itself what loads the view.
    func testRestoreWithTabsReopensThePanel() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("outline-restore-\(UUID().uuidString).md")
        try "# One\n\ntext\n".write(to: url, atomically: true, encoding: .utf8)
        scratch = url
        let record = WindowSession.TabRecord(path: url.path, bookmark: nil)
        let session = WindowSession(tabs: [record], activeIndex: 0,
                                    isSidebarVisible: false, isOutlineVisible: true)
        let root = RootSplitViewController(initialContent: .restoreSession(session))
        _ = hosted(root)
        XCTAssertTrue(root.isOutlinePanelVisibleForTesting)
        try assertPanelIsRealized(root)
    }

    func testRestoreWithoutTheFieldLeavesThePanelClosed() {
        let session = WindowSession(tabs: [], activeIndex: nil, isSidebarVisible: false)
        let root = RootSplitViewController(initialContent: .restoreSession(session))
        _ = hosted(root)
        XCTAssertFalse(root.isOutlinePanelVisibleForTesting)
        XCTAssertNil(root.editorForTesting.outlinePanelFrame)
        XCTAssertEqual(root.editorForTesting.activeContentTrailingPinForTesting, "edge")
    }
}
