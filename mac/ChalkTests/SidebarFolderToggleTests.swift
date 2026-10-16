import XCTest
import ChalkKit
@testable import Chalk

/// Crash-guard contract for SidebarViewController.toggleFolderExpansion
/// (2026-07-24, Catalyst: an exception inside the list's reconfigure, raised
/// by the first synthesized row click after a multi-window restore). The
/// toggle resolves the node against the live model, and a node missing from
/// every section is a no-op. These tests drive the same geometry: an
/// off-window outline view whose animated applies have not been ingested by a
/// layout pass.
@MainActor
final class SidebarFolderToggleTests: XCTestCase {
    private func tempTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-sidebar-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("# hi\n".utf8).write(to: folder.appendingPathComponent("a.md"))
        try Data("# root\n".utf8).write(to: root.appendingPathComponent("top.md"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeSidebar(root: URL) -> SidebarViewController {
        let sidebar = SidebarViewController()
        sidebar.locationsProvider = { [Location(id: "test", name: "Test", url: root)] }
        sidebar.loadViewIfNeeded() // builds the outline view + model, no window
        return sidebar
    }

    private func folderNode(in root: URL) throws -> FileNode {
        try XCTUnwrap(FileTree.children(of: root).first(where: \.isDirectory))
    }

    func testToggleExpandsAndCollapsesOffWindow() throws {
        let root = try tempTree()
        let sidebar = makeSidebar(root: root)
        let folder = try folderNode(in: root)

        sidebar.toggleFolderExpansionForTesting(folder)
        XCTAssertTrue(sidebar.isExpandedForTesting(folder))
        XCTAssertEqual(sidebar.rowsForTesting(inSection: 0).map(\.name), ["Notes", "a.md", "top.md"],
                       "the folder's children become rows")
        sidebar.toggleFolderExpansionForTesting(folder)
        XCTAssertFalse(sidebar.isExpandedForTesting(folder))
        XCTAssertEqual(sidebar.rowsForTesting(inSection: 0).map(\.name), ["Notes", "top.md"])
    }

    func testToggleImmediatelyAfterAnimatedReloadDoesNotRaise() throws {
        let root = try tempTree()
        let sidebar = makeSidebar(root: root)
        let folder = try folderNode(in: root)

        // An animated rebuild immediately before the click, like the restore race.
        sidebar.reload(animated: true)
        sidebar.toggleFolderExpansionForTesting(folder)
        XCTAssertTrue(sidebar.isExpandedForTesting(folder))
    }

    func testToggleWithStaleNodeIsANoOp() throws {
        let root = try tempTree()
        let sidebar = makeSidebar(root: root)
        let folder = try folderNode(in: root)

        // The folder vanishes from disk and from the model (external delete +
        // reload); a queued click for its old row must do nothing.
        try FileManager.default.removeItem(at: folder.url)
        sidebar.reload()
        sidebar.toggleFolderExpansionForTesting(folder)
        XCTAssertFalse(sidebar.isExpandedForTesting(folder))
    }

    func testToggleNodeThatNeverExistedIsANoOp() throws {
        let root = try tempTree()
        let sidebar = makeSidebar(root: root)
        let ghost = FileNode(
            url: root.appendingPathComponent("never-here", isDirectory: true),
            name: "never-here", isDirectory: true)
        sidebar.toggleFolderExpansionForTesting(ghost)
        XCTAssertFalse(sidebar.isExpandedForTesting(ghost))
    }

    /// A reload keeps an expanded folder open, with its rows.
    func testReloadKeepsExpansion() throws {
        let root = try tempTree()
        let sidebar = makeSidebar(root: root)
        let folder = try folderNode(in: root)
        sidebar.toggleFolderExpansionForTesting(folder)
        sidebar.reload()
        XCTAssertTrue(sidebar.isExpandedForTesting(folder))
        XCTAssertEqual(sidebar.rowsForTesting(inSection: 0).map(\.name), ["Notes", "a.md", "top.md"])
    }
}
