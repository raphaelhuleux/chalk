import XCTest
import ChalkKit
@testable import Chalk

/// The row menu's exact shape. Order is part of the design (open actions, then
/// edit actions, then create actions, then the destructive one last), so the
/// test asserts titles in order rather than set membership.
@MainActor
final class SidebarContextMenuTests: XCTestCase {
    private var sidebar: SidebarViewController!
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Papers"), withIntermediateDirectories: true)
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

    func testFileRowMenu() throws {
        let node = FileNode(url: root.appendingPathComponent("draft.tex"),
                            name: "draft.tex", isDirectory: false)
        let menu = sidebar.rowMenu(for: node)
        XCTAssertEqual(titles(menu), [
            "Open", "Open in New Tab", "Open in New Window",
            "Rename", "Duplicate", "Copy", "Copy Path",
            "New File", "New Folder",
            "Move to Trash",
        ])
    }

    func testFolderRowMenu() throws {
        let node = FileNode(url: root.appendingPathComponent("Papers"),
                            name: "Papers", isDirectory: true)
        let menu = sidebar.rowMenu(for: node)
        XCTAssertEqual(titles(menu), [
            "New File", "New Folder",
            "Rename", "Duplicate", "Copy", "Copy Path",
            "Move to Trash",
        ], "a folder is not a document: no Open in New Window")
    }

    /// Separators keep the destructive item apart, as the design draws it.
    func testGroupsAreSeparated() throws {
        let node = FileNode(url: root.appendingPathComponent("draft.tex"),
                            name: "draft.tex", isDirectory: false)
        let menu = sidebar.rowMenu(for: node)
        XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, 3, "four groups, three separators")
        XCTAssertTrue(menu.items.last?.title == "Move to Trash")
    }

    func testMoveToTrashIsDestructive() throws {
        let node = FileNode(url: root.appendingPathComponent("draft.tex"),
                            name: "draft.tex", isDirectory: false)
        let menu = sidebar.rowMenu(for: node)
        XCTAssertEqual(try XCTUnwrap(item(in: menu, titled: "Move to Trash")).tag,
                       SidebarViewController.destructiveTag)
    }

    /// The menu is the only pointer route into rename (round 3, 2026-08-18):
    /// a right-click lands here.
    func testRenameActionStartsTheInlineEditor() throws {
        let node = FileNode(url: root.appendingPathComponent("draft.tex"),
                            name: "draft.tex", isDirectory: false)
        let menu = sidebar.rowMenu(for: node)
        perform(try XCTUnwrap(item(in: menu, titled: "Rename")))
        XCTAssertTrue(sidebar.isRenamingForTesting)
    }

    func testFolderRenameActionStartsTheInlineEditor() throws {
        let node = FileNode(url: root.appendingPathComponent("Papers"),
                            name: "Papers", isDirectory: true)
        let menu = sidebar.rowMenu(for: node)
        perform(try XCTUnwrap(item(in: menu, titled: "Rename")))
        XCTAssertTrue(sidebar.isRenamingForTesting, "folders rename through the menu too")
    }

    func testNewFileOnAFileRowTargetsItsContainingFolder() throws {
        let nested = root.appendingPathComponent("Papers/nested.md")
        try "x".write(to: nested, atomically: true, encoding: .utf8)
        var created: [URL] = []
        sidebar.onOpenCreatedFile = { created.append($0) }
        let node = FileNode(url: nested, name: "nested.md", isDirectory: false)
        let menu = sidebar.rowMenu(for: node)
        // New File writes off the main thread, so `onOpenCreatedFile` reports
        // once the work lands.
        let newFile = try XCTUnwrap(item(in: menu, titled: "New File"))
        awaitFileWork(on: sidebar) { perform(newFile) }
        XCTAssertEqual(created.first?.deletingLastPathComponent().standardizedFileURL.path,
                       root.appendingPathComponent("Papers").standardizedFileURL.path,
                       "New File beside a file lands in that file's folder, not the Location root")
    }

    /// The header's menu: create actions, then the destructive removal; a
    /// Location that lost access offers the re-grant instead.
    func testHeaderMenu() throws {
        let live = sidebar.headerMenu(for: Location(id: "test", name: "Root", url: root))
        XCTAssertEqual(titles(live), ["New File", "New Folder", "Remove from Window"])
        let dead = sidebar.headerMenu(for: Location(id: "dead", name: "Gone", url: root, needsReauthorization: true))
        XCTAssertEqual(titles(dead), ["Grant Access\u{2026}", "Remove from Window"])
        XCTAssertEqual(try XCTUnwrap(item(in: live, titled: "Remove from Window")).tag,
                       SidebarViewController.destructiveTag)
    }
}
