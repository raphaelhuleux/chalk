import XCTest
import ChalkKit
@testable import Chalk

/// The 2026-08-24 report: "renaming a file in the sidebar and pressing enter
/// crashes the app", and the same for dragging a file into a folder. It was not
/// a crash, it was the main thread blocked: every sidebar file operation ran on
/// it, and the owner's Library lives under an iCloud-synced folder, where a
/// coordinated write waits for the CloudDocs daemon, `copyItem` on a dataless
/// file materializes it first, and every name probe crosses the sync layer.
///
/// So this suite asserts WHICH THREAD the work runs on. Two oracles, because
/// the paths differ: `runFileWork`'s probe for the `FileManager` operations,
/// and for the move the observable consequence of being asynchronous (the disk
/// has not changed yet when the call returns).
///
/// `CoordinatedFileMoveTests` (ChalkKit) covers the move's own contract.
@MainActor
final class SidebarFileWorkThreadingTests: XCTestCase {
    private var sidebar: SidebarViewController!
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Documents, not tmp: `trashItem` is volume-sensitive and this is where
        // real Locations live (matching SidebarFileOperationsTests).
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chalk-threading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("draft.tex"),
                          atomically: true, encoding: .utf8)
        sidebar = SidebarViewController()
        sidebar.locationsProvider = { [Location(id: "test", name: "Root", url: self.root)] }
        sidebar.loadViewIfNeeded()
        sidebar.reload()
        SidebarViewController.lastFileWorkRanOnMainThread = nil
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

    // MARK: - The FileManager operations

    /// The probe is written on the work queue and read after the completion has
    /// landed on main, so the wait orders the two.
    private func assertRanOffTheMainThread(
        _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(SidebarViewController.lastFileWorkRanOnMainThread, false,
                       "\(what) still runs on the thread that draws",
                       file: file, line: line)
    }

    func testDuplicateRunsOffTheMainThread() {
        awaitFileWork(on: sidebar) { sidebar.duplicate(node("draft.tex")) }
        assertRanOffTheMainThread("Duplicate")
        XCTAssertTrue(exists("draft 2.tex"), "and it still duplicates")
    }

    func testMoveToTrashRunsOffTheMainThread() throws {
        try XCTSkipUnless(canTrash(in: root), "this sandbox refuses trashItem")
        awaitFileWork(on: sidebar) { sidebar.moveToTrash(node("draft.tex")) }
        assertRanOffTheMainThread("Move to Trash")
        XCTAssertFalse(exists("draft.tex"), "and it still trashes")
    }

    func testNewFileRunsOffTheMainThread() {
        awaitFileWork(on: sidebar) { sidebar.createFileForTesting(in: root) }
        assertRanOffTheMainThread("New File")
    }

    func testNewFolderRunsOffTheMainThread() {
        awaitFileWork(on: sidebar) { sidebar.createFolderForTesting(in: root) }
        assertRanOffTheMainThread("New Folder")
        XCTAssertTrue(exists("Untitled Folder"), "and it still creates the folder")
    }

    /// Expanding a folder reads one directory per revealed subfolder. On an
    /// iCloud Library, opening a folder blocked the main thread too.
    func testExpandingAFolderReadsOffTheMainThread() throws {
        let folder = root.appendingPathComponent("Papers")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        sidebar.reload()
        // The tree's own node, not a hand-built one: `contentsOfDirectory`
        // returns directory URLs with a trailing slash, so a constructed
        // FileNode compares unequal and the expansion silently does nothing.
        let papers = try XCTUnwrap(FileTree.children(of: root).first { $0.name == "Papers" })
        SidebarViewController.lastExpansionReadRanOnMainThread = nil
        awaitExpansionWork(on: sidebar) { sidebar.toggleFolderExpansionForTesting(papers) }
        XCTAssertEqual(SidebarViewController.lastExpansionReadRanOnMainThread, false,
                       "expanding a folder still reads the disk on the thread that draws")
    }

    // MARK: - The move (rename and drag-move share it)

    /// The move is asynchronous, and this is the observable proof: the file is
    /// still where it was when the call returns.
    func testRenameDoesNotTouchTheDiskBeforeItReturns() {
        awaitFileWork(on: sidebar) {
            sidebar.beginRename(node("draft.tex"))
            sidebar.commitRename("notes.tex")
            XCTAssertTrue(exists("draft.tex"),
                          "the coordinated write must not have run on this thread")
            XCTAssertFalse(exists("notes.tex"))
        }
        XCTAssertTrue(exists("notes.tex"), "and it lands once the work completes")
        XCTAssertFalse(exists("draft.tex"))
    }

    /// The editor closes on the synchronous verdict, not on the move: the field
    /// IS the row, and leaving it open across an async move would keep the caret
    /// in a row the refresh is about to replace.
    func testRenameClosesTheEditorImmediately() {
        awaitFileWork(on: sidebar) {
            sidebar.beginRename(node("draft.tex"))
            sidebar.commitRename("notes.tex")
            XCTAssertFalse(sidebar.isRenamingForTesting)
        }
    }

    /// Drag-move, the second report, through the same function.
    func testDragMoveDoesNotTouchTheDiskBeforeItReturns() throws {
        let folder = root.appendingPathComponent("Papers")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("draft.tex")
        awaitFileWork(on: sidebar) {
            let started = sidebar.moveFile(
                from: source, to: folder.appendingPathComponent("draft.tex"),
                actionName: "Move", animated: true)
            XCTAssertTrue(started, "the pre-flight passes: no collision in the target")
            XCTAssertTrue(exists("draft.tex"), "still on disk while the move is in flight")
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("draft.tex").path))
    }

    /// A collision is still refused synchronously: the callers read that
    /// verdict to shake the field or to raise "Couldn't move … there", and
    /// nothing asynchronous may happen in that case.
    func testACollisionIsRefusedWithoutStartingAnyWork() throws {
        try "other".write(to: root.appendingPathComponent("taken.tex"),
                          atomically: true, encoding: .utf8)
        var finished = false
        sidebar.onFileWorkFinishedForTesting = { finished = true }
        let started = sidebar.moveFile(
            from: root.appendingPathComponent("draft.tex"),
            to: root.appendingPathComponent("taken.tex"),
            actionName: "Rename")
        XCTAssertFalse(started)
        // One turn of the main queue is enough for any work that had been
        // dispatched to report back.
        let settled = expectation(description: "one runloop turn")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertFalse(finished, "a refused move must not start any file work")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("taken.tex"), encoding: .utf8),
            "other", "and the existing file is untouched")
        sidebar.onFileWorkFinishedForTesting = nil
    }
}
