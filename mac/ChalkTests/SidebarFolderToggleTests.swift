import XCTest
import ChalkKit
@testable import Chalk

/// Crash-guard contract for SidebarViewController.toggleFolderExpansion
/// (2026-07-24 SIGABRT: NSException inside UICollectionView
/// reconfigureItemsAtIndexPaths, raised by the first synthesized row click
/// after a multi-window restore). The toggle now validates the index path
/// against the collection view's CURRENT counts before reconfiguring, and a
/// node missing from every section snapshot is a no-op. These tests drive the
/// exact geometry that raised: an off-window collection view whose animated
/// snapshot applies have not been ingested by a layout pass.
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
        sidebar.loadViewIfNeeded() // builds the collection view + data source, no window
        return sidebar
    }

    private func folderNode(in root: URL) throws -> FileNode {
        try XCTUnwrap(FileTree.children(of: root).first(where: \.isDirectory))
    }

    func testToggleExpandsAndCollapsesOffWindow() throws {
        let root = try tempTree()
        let sidebar = makeSidebar(root: root)
        let folder = try folderNode(in: root)

        // The crash path: toggle drives an ANIMATED section-snapshot apply and
        // then a reconfigure, on a collection view that has never laid out.
        sidebar.toggleFolderExpansionForTesting(folder)
        XCTAssertTrue(sidebar.isExpandedForTesting(folder))
        sidebar.toggleFolderExpansionForTesting(folder)
        XCTAssertFalse(sidebar.isExpandedForTesting(folder))
    }

    func testToggleImmediatelyAfterAnimatedReloadDoesNotRaise() throws {
        let root = try tempTree()
        let sidebar = makeSidebar(root: root)
        let folder = try folderNode(in: root)

        // An animated rebuild immediately before the click, like the restore
        // race: the data source's snapshot is ahead of the collection view.
        sidebar.reload(animated: true)
        sidebar.toggleFolderExpansionForTesting(folder)
        XCTAssertTrue(sidebar.isExpandedForTesting(folder))
    }

    func testToggleWithStaleNodeIsANoOp() throws {
        let root = try tempTree()
        let sidebar = makeSidebar(root: root)
        let folder = try folderNode(in: root)

        // The folder vanishes from disk and from the snapshot (external
        // delete + reload); a queued click for its old row must do nothing.
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
}
