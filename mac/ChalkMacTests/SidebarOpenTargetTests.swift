import XCTest
import ChalkKit
@testable import ChalkMac

/// The three open paths the row menu offers are distinct callbacks, so the
/// window layer decides tab reuse rather than the sidebar guessing.
@MainActor
final class SidebarOpenTargetTests: XCTestCase {
    private var sidebar: SidebarViewController!
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("draft.tex"), atomically: true, encoding: .utf8)
        sidebar = SidebarViewController()
        sidebar.locationsProvider = { [Location(id: "test", name: "Root", url: self.root)] }
        sidebar.loadViewIfNeeded()
        sidebar.reload()
    }

    override func tearDownWithError() throws {
        sidebar = nil
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testNewTabAndNewWindowActionsCallTheirOwnCallbacks() throws {
        var tabbed: [URL] = []
        var windowed: [URL] = []
        var opened: [URL] = []
        sidebar.onOpenFile = { opened.append($0) }
        sidebar.onOpenFileInNewTab = { tabbed.append($0) }
        sidebar.onOpenFileInNewWindow = { windowed.append($0) }

        let file = root.appendingPathComponent("draft.tex")
        let node = FileNode(url: file, name: "draft.tex", isDirectory: false)
        let menu = sidebar.rowMenu(for: node)

        perform(try XCTUnwrap(item(in: menu, titled: "Open")))
        perform(try XCTUnwrap(item(in: menu, titled: "Open in New Tab")))
        perform(try XCTUnwrap(item(in: menu, titled: "Open in New Window")))

        XCTAssertEqual(opened, [file])
        XCTAssertEqual(tabbed, [file])
        XCTAssertEqual(windowed, [file])
    }
}
