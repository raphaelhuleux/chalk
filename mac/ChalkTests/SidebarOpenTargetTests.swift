import XCTest
import ChalkKit
@testable import Chalk

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

        try perform(menu, titled: "Open")
        try perform(menu, titled: "Open in New Tab")
        try perform(menu, titled: "Open in New Window")

        XCTAssertEqual(opened, [file])
        XCTAssertEqual(tabbed, [file])
        XCTAssertEqual(windowed, [file])
    }

    /// Fire the action with `title` wherever it sits in the menu tree.
    private func perform(_ menu: UIMenu, titled title: String) throws {
        func find(_ menu: UIMenu) -> UIAction? {
            for element in menu.children {
                if let action = element as? UIAction, action.title == title { return action }
                if let submenu = element as? UIMenu, let hit = find(submenu) { return hit }
            }
            return nil
        }
        let action = try XCTUnwrap(find(menu), "no menu item titled \(title)")
        action.performWithSender(nil, target: nil)
    }
}
