import XCTest
import ChalkKit
@testable import ChalkMac

/// Window restoration on the AppKit shell: a window's record (id, tabs,
/// active tab, sidebar, outline panel, frame) round-trips through the
/// journal, unreadable files drop silently, a closed window leaves the
/// journal and takes its Locations with it, and the delegate brings every
/// journaled window back.
@MainActor
final class WindowRestorationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var tempDir: URL!
    private var controllers: [EditorWindowController] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "chalk-restoration-\(UUID().uuidString)"))
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-restoration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for controller in controllers { controller.close() }
        controllers = []
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func writeFile(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func session(_ urls: [URL], activeIndex: Int?, sidebar: Bool = false, outline: Bool = false) -> WindowSession {
        WindowSession(
            tabs: urls.map { WindowSession.TabRecord(path: $0.path, bookmark: nil) },
            activeIndex: activeIndex, isSidebarVisible: sidebar, isOutlineVisible: outline)
    }

    /// A frame that is on the main screen, so restoring it does not fall
    /// back to centring.
    private var onScreenFrame: NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        return NSRect(x: visible.minX + 24, y: visible.minY + 24, width: 1000, height: 700)
    }

    func testARestoredSessionReopensReadableTabsAndDropsTheRest() throws {
        let a = try writeFile("a.md")
        let b = try writeFile("b.md")
        let missing = tempDir.appendingPathComponent("gone.md")
        let controller = EditorWindowController(
            initialContent: .restoreSession(session([a, missing, b], activeIndex: 2, sidebar: true, outline: true)))
        controllers.append(controller)
        let root = controller.root
        XCTAssertEqual(root.openTabCount, 2, "the file that is gone drops silently")
        XCTAssertEqual(root.editor.sessionSnapshot().activeIndex, 1,
                       "the active tab follows the record that survived, not its old index")
        XCTAssertTrue(root.isSidebarVisible)
        XCTAssertTrue(root.editor.isOutlinePanelVisible)
    }

    func testTheWindowRecordCarriesIdTabsAndFrame() throws {
        let a = try writeFile("a.md")
        let controller = EditorWindowController(windowID: "win-A", initialContent: .openEmpty, frame: onScreenFrame)
        controllers.append(controller)
        controller.root.openExternalDocument(a)

        let record = controller.windowRecord()
        XCTAssertEqual(record.id, "win-A")
        XCTAssertEqual(record.session.tabs.map(\.path), [a.path])
        XCTAssertEqual(record.session.activeIndex, 0)
        let frame = try XCTUnwrap(record.frame)
        XCTAssertEqual(frame.width, onScreenFrame.width, accuracy: 1)
        XCTAssertEqual(frame.height, onScreenFrame.height, accuracy: 1)
    }

    func testAJournaledWindowComesBackWhereItWas() throws {
        let a = try writeFile("a.md")
        let journal = WindowSessionJournal(defaults: defaults)
        let wanted = onScreenFrame
        journal.save([WindowRecord(
            id: "win-A", session: session([a], activeIndex: 0),
            frame: .init(x: wanted.minX, y: wanted.minY, width: wanted.width, height: wanted.height))])

        let record = try XCTUnwrap(journal.load().first)
        let controller = EditorWindowController(
            windowID: record.id, initialContent: .restoreSession(record.session),
            frame: NSRect(x: record.frame!.x, y: record.frame!.y, width: record.frame!.width, height: record.frame!.height))
        controllers.append(controller)
        let frame = try XCTUnwrap(controller.window?.frame)
        // The size only: the test host's windows all report a zero origin
        // (a plain NSWindow made at (24, 24) does too), so the position is
        // not checkable here.
        XCTAssertEqual(frame.width, wanted.width, accuracy: 1)
        XCTAssertEqual(frame.height, wanted.height, accuracy: 1)
        XCTAssertNotNil(controller.window?.screen)
        XCTAssertEqual(controller.root.openTabCount, 1)
    }

    /// A frame below the window floor, or off every screen, is not restored.
    func testAnUnusableFrameFallsBackToTheDefault() throws {
        let tiny = EditorWindowController(initialContent: .openEmpty, frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        controllers.append(tiny)
        XCTAssertEqual(tiny.window?.frame.width ?? 0, EditorWindowController.defaultSize.width, accuracy: 1)
        let gone = EditorWindowController(initialContent: .openEmpty, frame: NSRect(x: 90_000, y: 90_000, width: 1000, height: 700))
        controllers.append(gone)
        XCTAssertNotNil(gone.window?.screen, "a frame from a display that is gone lands on screen")
    }

    // MARK: - The delegate's journal

    func testTheDelegateRestoresEveryJournaledWindowInOrder() throws {
        let a = try writeFile("a.md")
        WindowSessionJournal(defaults: defaults).save([
            WindowRecord(id: "win-A", session: session([a], activeIndex: 0)),
            WindowRecord(id: "win-B", session: session([], activeIndex: nil)),
        ])
        let delegate = AppDelegate(defaults: defaults)
        delegate.restoreWindows()
        controllers = delegate.editorWindows
        XCTAssertEqual(delegate.editorWindows.map(\.windowID), ["win-A", "win-B"])
        XCTAssertEqual(delegate.editorWindows[0].root.openTabCount, 1)
        XCTAssertEqual(delegate.editorWindows[1].root.openTabCount, 0)
    }

    func testAClosedWindowLeavesTheJournalAndTakesItsLocations() throws {
        let delegate = AppDelegate(defaults: defaults)
        let a = delegate.openNewWindow(initialContent: .openEmpty)
        let b = delegate.openNewWindow(initialContent: .openEmpty)
        controllers = [a, b]
        // Each window has its own Locations list from the start.
        XCTAssertNotNil(defaults.object(forKey: WindowLocations.key(forWindow: a.windowID)))
        XCTAssertNotNil(defaults.object(forKey: WindowLocations.key(forWindow: b.windowID)))

        delegate.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification))
        let journal = WindowSessionJournal(defaults: defaults)
        XCTAssertEqual(Set(journal.load().map(\.id)), [a.windowID, b.windowID])

        a.close()
        controllers = [b]
        XCTAssertEqual(journal.load().map(\.id), [b.windowID], "a closed window must not come back")
        XCTAssertNil(defaults.object(forKey: WindowLocations.key(forWindow: a.windowID)),
                     "its folders go with it")
        XCTAssertEqual(delegate.editorWindows.map(\.windowID), [b.windowID])
    }

    /// New Window is a deliberately fresh window: empty, no Welcome.
    func testNewWindowOpensEmpty() {
        let delegate = AppDelegate(defaults: defaults)
        delegate.cmdNewWindow(nil)
        controllers = delegate.editorWindows
        XCTAssertEqual(delegate.editorWindows.count, 1)
        XCTAssertEqual(delegate.editorWindows[0].root.openTabCount, 0)
    }
}
