import XCTest
import ChalkKit
@testable import Chalk

/// Async-reload race (2026-08-15): `scheduleReload` captures expansion state
/// on main, builds off-main, then applies back on main. The build window is
/// unbounded (iCloud ubiquity daemon), and folds/unfolds made while it is in
/// flight touch the live tree directly, without bumping reloadGeneration, so
/// a stale build's apply used to snap those folders back to their captured
/// state and drop their lazily loaded children.
///
/// Contract under test: `applySections` overlays the live expansion state
/// onto the built trees at apply time, so a stale build can refresh the tree
/// without reverting any interaction that happened mid-build.
/// `makeStaleReloadApplyForTesting` reproduces the race window
/// deterministically: it captures + builds synchronously and returns the
/// deferred apply.
@MainActor
final class SidebarReloadRaceTests: XCTestCase {
    private func tempTree() throws -> URL {
        // Root/
        //   Papers/
        //     Sub/deep.md
        //     draft.tex
        //   index.md
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-reload-race-\(UUID().uuidString)")
        let papers = root.appendingPathComponent("Papers", isDirectory: true)
        let sub = papers.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("# deep\n".utf8).write(to: sub.appendingPathComponent("deep.md"))
        try Data("x".utf8).write(to: papers.appendingPathComponent("draft.tex"))
        try Data("# root\n".utf8).write(to: root.appendingPathComponent("index.md"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeSidebar(root: URL) -> SidebarViewController {
        let sidebar = SidebarViewController()
        sidebar.locationsProvider = { [Location(id: "test", name: "Test", url: root)] }
        sidebar.loadViewIfNeeded() // builds the outline view + model, no window
        return sidebar
    }

    private func node(named name: String, in directory: URL) throws -> FileNode {
        try XCTUnwrap(FileTree.children(of: directory).first { $0.name == name },
                      "fixture should contain \(name)")
    }

    func testStaleApplyKeepsExpansionMadeDuringBuild() throws {
        let root = try tempTree()
        let sidebar = makeSidebar(root: root)
        let papers = try node(named: "Papers", in: root)

        let staleApply = sidebar.makeStaleReloadApplyForTesting() // captured: collapsed
        sidebar.toggleFolderExpansionForTesting(papers)
        XCTAssertTrue(sidebar.isExpandedForTesting(papers))

        staleApply() // the in-flight build lands late
        XCTAssertTrue(sidebar.isExpandedForTesting(papers),
                      "a stale build's apply must not fold a folder expanded mid-build")
        let sub = try node(named: "Sub", in: papers.url)
        XCTAssertTrue(sidebar.containsNodeForTesting(sub),
                      "the expanded folder's children must survive the apply")
        XCTAssertTrue(sidebar.rowsForTesting(inSection: 0).contains(sub), "and stay rows")
    }

    func testStaleApplyKeepsCollapseMadeDuringBuild() throws {
        let root = try tempTree()
        let sidebar = makeSidebar(root: root)
        let papers = try node(named: "Papers", in: root)

        sidebar.toggleFolderExpansionForTesting(papers)
        let staleApply = sidebar.makeStaleReloadApplyForTesting() // captured: expanded
        sidebar.toggleFolderExpansionForTesting(papers)
        XCTAssertFalse(sidebar.isExpandedForTesting(papers))

        staleApply()
        XCTAssertFalse(sidebar.isExpandedForTesting(papers),
                       "a stale build's apply must not reopen a folder collapsed mid-build")
        XCTAssertEqual(sidebar.rowsForTesting(inSection: 0).map(\.name), ["Papers", "index.md"])
    }

    func testStaleApplyLoadsChildrenOfFolderExpandedDeepDuringBuild() throws {
        let root = try tempTree()
        let sidebar = makeSidebar(root: root)
        let papers = try node(named: "Papers", in: root)
        let sub = try node(named: "Sub", in: papers.url)

        // Capture while everything is collapsed: the build walks Sub's row in
        // (one level ahead) but never Sub's children.
        let staleApply = sidebar.makeStaleReloadApplyForTesting()
        // Expanding Papers reads Sub's children off the main thread, and it is
        // those children the stale apply has to carry over, so wait for them
        // before it lands.
        awaitExpansionWork(on: sidebar) { sidebar.toggleFolderExpansionForTesting(papers) }
        sidebar.toggleFolderExpansionForTesting(sub)
        XCTAssertTrue(sidebar.isExpandedForTesting(sub))

        staleApply()
        XCTAssertTrue(sidebar.isExpandedForTesting(papers))
        XCTAssertTrue(sidebar.isExpandedForTesting(sub),
                      "a deep expansion made mid-build must survive the apply")
        let deep = try node(named: "deep.md", in: sub.url)
        XCTAssertTrue(sidebar.containsNodeForTesting(deep),
                      "the apply must backfill children the build never walked")
        XCTAssertTrue(sidebar.rowsForTesting(inSection: 0).contains(deep))
    }

    func testFreshBuildStillWinsForFoldersUntouchedDuringBuild() throws {
        // The overlay must not freeze the whole tree: rows the user did NOT
        // touch mid-build take the fresh build's content (here: a file
        // created on disk after the capture).
        let root = try tempTree()
        let sidebar = makeSidebar(root: root)

        sidebar.reload()
        try Data("# new\n".utf8).write(to: root.appendingPathComponent("new.md"))
        let staleApply = sidebar.makeStaleReloadApplyForTesting() // sees new.md
        staleApply()
        let new = try node(named: "new.md", in: root)
        XCTAssertTrue(sidebar.containsNodeForTesting(new),
                      "the fresh tree content must still land")
    }

    // MARK: - Never blank the tree on an ordinary reload

    /// The Location list is only rebuilt (a full table reload, every row
    /// re-dequeued) when the Locations themselves change; a reload that only
    /// changes files reconciles rows in place. The Catalyst list went blank
    /// for a turn on every reload ("the side panel is sometimes empty",
    /// 2026-08-17); the rule is kept as a pure function.
    private func locations(_ ids: [String]) -> [Location] {
        ids.map { Location(id: $0, name: $0, url: URL(fileURLWithPath: "/tmp/\($0)")) }
    }

    func testUnchangedLocationsSkipTheRebuild() {
        XCTAssertFalse(
            SidebarViewController.sectionsNeedApply(locations(["a", "b"]), locations(["a", "b"])),
            "an ordinary reload must not rebuild the list")
    }

    func testAddedLocationStillApplies() {
        XCTAssertTrue(
            SidebarViewController.sectionsNeedApply(locations(["a", "b"]), locations(["a"])))
    }

    func testRemovedLocationStillApplies() {
        XCTAssertTrue(
            SidebarViewController.sectionsNeedApply(locations(["a"]), locations(["a", "b"])))
    }

    func testReorderedLocationsStillApply() {
        XCTAssertTrue(
            SidebarViewController.sectionsNeedApply(locations(["b", "a"]), locations(["a", "b"])))
    }

    /// The end-to-end guard: a reload that only changes files keeps every row,
    /// and keeps the row OBJECTS, which is what keeps their table state.
    func testReloadAfterAFileAppearsNeverLosesTheExistingRows() throws {
        let root = try tempTree()
        let sidebar = makeSidebar(root: root)
        sidebar.reload()
        let index = try node(named: "index.md", in: root)
        XCTAssertTrue(sidebar.containsNodeForTesting(index))
        let indexItem = try XCTUnwrap(sidebar.item(for: index))

        try Data("# two\n".utf8).write(to: root.appendingPathComponent("two.md"))
        sidebar.reload()
        XCTAssertTrue(sidebar.containsNodeForTesting(index), "existing rows survive")
        XCTAssertTrue(sidebar.item(for: index) === indexItem, "as the same objects")
        XCTAssertTrue(sidebar.containsNodeForTesting(try node(named: "two.md", in: root)))
        XCTAssertEqual(sidebar.rowsForTesting(inSection: 0).map(\.name), ["Papers", "index.md", "two.md"])
    }

    /// A Location that comes or goes rebuilds the list and keeps the others'
    /// expansion.
    func testAddingALocationKeepsTheOthersExpansion() throws {
        let root = try tempTree()
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-reload-race-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: other) }
        let sidebar = makeSidebar(root: root)
        let papers = try node(named: "Papers", in: root)
        sidebar.toggleFolderExpansionForTesting(papers)

        sidebar.locationsProvider = { [
            Location(id: "test", name: "Test", url: root),
            Location(id: "other", name: "Other", url: other),
        ] }
        sidebar.reload()
        XCTAssertEqual(sidebar.sections.count, 2)
        XCTAssertTrue(sidebar.isExpandedForTesting(papers))
        XCTAssertEqual(sidebar.rowsForTesting(inSection: 0).map(\.name), ["Papers", "Sub", "draft.tex", "index.md"])
        XCTAssertEqual(sidebar.rowsForTesting(inSection: 1).map(\.name), ["Empty"])
    }
}
