import XCTest
import ChalkKit
@testable import Chalk

/// Duplicate and Move to Trash against a real temp directory, each followed by
/// the undo the sidebar registers. Trash goes through `FileManager.trashItem`,
/// which a sandbox can refuse — those tests skip rather than fail.
@MainActor
final class SidebarFileOperationsTests: XCTestCase {
    private var sidebar: SidebarViewController!
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Inside Documents, not the temp directory: that is where real
        // Locations live, and `trashItem` is volume-sensitive — testing it
        // anywhere else answers the wrong question.
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chalk-ops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("draft.tex"), atomically: true, encoding: .utf8)
        let location = Location(id: "test", name: "Root", url: root)
        sidebar = SidebarViewController()
        sidebar.locationsProvider = { [location] }
        sidebar.loadViewIfNeeded()
        sidebar.reload()
    }

    override func tearDownWithError() throws {
        sidebar = nil
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func node(_ name: String, isDirectory: Bool = false) -> FileNode {
        FileNode(url: root.appendingPathComponent(name), name: name, isDirectory: isDirectory)
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    func testDuplicateCreatesANumberedCopyWithTheSameContents() throws {
        // Off the main thread since 2026-08-24 (the sidebar freeze), so the
        // assertions wait for the work rather than racing it.
        awaitFileWork(on: sidebar) { sidebar.duplicate(node("draft.tex")) }
        XCTAssertTrue(exists("draft 2.tex"))
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("draft 2.tex"), encoding: .utf8),
            "hello")
        XCTAssertTrue(exists("draft.tex"), "the original stays")
    }

    func testDuplicateTwiceCountsUp() {
        // Serially, on purpose: the second name probe has to see the first copy.
        awaitFileWork(on: sidebar) { sidebar.duplicate(node("draft.tex")) }
        awaitFileWork(on: sidebar) { sidebar.duplicate(node("draft.tex")) }
        XCTAssertTrue(exists("draft 2.tex"))
        XCTAssertTrue(exists("draft 3.tex"))
    }

    func testUndoRemovesTheDuplicate() throws {
        try XCTSkipUnless(canTrash(), "this sandbox refuses trashItem")
        awaitFileWork(on: sidebar) { sidebar.duplicate(node("draft.tex")) }
        XCTAssertTrue(exists("draft 2.tex"))
        awaitFileWork(on: sidebar) { sidebar.undoManager?.undo() }
        XCTAssertFalse(exists("draft 2.tex"), "undoing a duplicate takes the copy away")
        XCTAssertTrue(exists("draft.tex"))
    }

    func testMoveToTrashRemovesTheFile() throws {
        try XCTSkipUnless(canTrash(), "this sandbox refuses trashItem")
        awaitFileWork(on: sidebar) { sidebar.moveToTrash(node("draft.tex")) }
        XCTAssertFalse(exists("draft.tex"))
    }

    func testUndoRestoresATrashedFile() throws {
        try XCTSkipUnless(canTrash(), "this sandbox refuses trashItem")
        awaitFileWork(on: sidebar) { sidebar.moveToTrash(node("draft.tex")) }
        XCTAssertFalse(exists("draft.tex"))
        awaitFileWork(on: sidebar) { sidebar.undoManager?.undo() }
        XCTAssertTrue(exists("draft.tex"), "undo brings it back from the Trash")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("draft.tex"), encoding: .utf8),
            "hello")
    }

    /// Probe once: some sandboxes have no Trash for the temp volume.
    /// Every window shows the Library, so each operation that changes the
    /// tree must tell them all, not reload only the window it ran in.
    func testEveryFileOperationTellsEveryLibrary() throws {
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .chalkLibraryDidChange, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        awaitFileWork(on: sidebar) { sidebar.duplicate(node("draft.tex")) }
        XCTAssertEqual(posts, 1, "Duplicate")
        awaitFileWork(on: sidebar) { sidebar.createFileForTesting(in: root) }
        XCTAssertEqual(posts, 2, "New File")
        awaitFileWork(on: sidebar) { sidebar.createFolderForTesting(in: root) }
        XCTAssertEqual(posts, 3, "New Folder")

        try XCTSkipUnless(canTrash(), "this sandbox refuses trashItem")
        awaitFileWork(on: sidebar) { sidebar.moveToTrash(node("draft 2.tex")) }
        XCTAssertEqual(posts, 4, "Move to Trash")
    }

    private func canTrash() -> Bool {
        let probe = root.appendingPathComponent("trash-probe")
        guard (try? Data().write(to: probe)) != nil else { return false }
        var resulting: NSURL?
        let ok = (try? FileManager.default.trashItem(at: probe, resultingItemURL: &resulting)) != nil
        if let resulting = resulting as URL? { try? FileManager.default.removeItem(at: resulting) }
        try? FileManager.default.removeItem(at: probe)
        return ok
    }
}
