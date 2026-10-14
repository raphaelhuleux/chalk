import XCTest
import ChalkKit
@testable import Chalk

/// Inline rename replaces the alert (U11). The row itself edits, so the tests
/// drive the lifecycle rather than a dialog: begin, commit, cancel, and the
/// two rejection paths that must NOT close the editor.
@MainActor
final class SidebarInlineRenameTests: XCTestCase {
    private var sidebar: SidebarViewController!
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("draft.tex"), atomically: true, encoding: .utf8)
        try "other".write(to: root.appendingPathComponent("taken.tex"), atomically: true, encoding: .utf8)
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

    private func draft() -> FileNode {
        FileNode(url: root.appendingPathComponent("draft.tex"), name: "draft.tex", isDirectory: false)
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    func testBeginPutsTheRowInEditing() {
        sidebar.beginRename(draft())
        XCTAssertTrue(sidebar.isRenamingForTesting)
    }

    func testCommitRenamesOnDiskAndEndsEditing() {
        sidebar.beginRename(draft())
        // The move runs off the main thread (2026-08-24 freeze), so the on-disk
        // assertions wait for it; the editor state below is decided
        // synchronously and would hold either way.
        awaitFileWork(on: sidebar) { sidebar.commitRename("notes.tex") }
        XCTAssertTrue(exists("notes.tex"))
        XCTAssertFalse(exists("draft.tex"))
        XCTAssertFalse(sidebar.isRenamingForTesting)
    }

    func testCommitPreservesContents() throws {
        sidebar.beginRename(draft())
        awaitFileWork(on: sidebar) { sidebar.commitRename("notes.tex") }
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("notes.tex"), encoding: .utf8),
            "hello")
    }

    func testCancelChangesNothing() {
        sidebar.beginRename(draft())
        sidebar.cancelRename()
        XCTAssertTrue(exists("draft.tex"))
        XCTAssertFalse(sidebar.isRenamingForTesting)
    }

    func testCollisionKeepsTheEditorOpenAndTouchesNothing() {
        sidebar.beginRename(draft())
        sidebar.commitRename("taken.tex")
        XCTAssertTrue(sidebar.isRenamingForTesting, "a rejected name must not close the editor")
        XCTAssertTrue(exists("draft.tex"))
        XCTAssertEqual(try? String(contentsOf: root.appendingPathComponent("taken.tex"), encoding: .utf8),
                       "other", "the existing file is untouched")
    }

    func testInvalidNameKeepsTheEditorOpen() {
        sidebar.beginRename(draft())
        sidebar.commitRename("sub/notes.tex")
        XCTAssertTrue(sidebar.isRenamingForTesting)
        XCTAssertTrue(exists("draft.tex"))
    }

    func testUndoRestoresTheOldName() {
        sidebar.beginRename(draft())
        awaitFileWork(on: sidebar) { sidebar.commitRename("notes.tex") }
        awaitFileWork(on: sidebar) { sidebar.undoManager?.undo() }
        XCTAssertTrue(exists("draft.tex"))
        XCTAssertFalse(exists("notes.tex"))
    }

    func testCaseOnlyRenameIsAllowed() {
        sidebar.beginRename(draft())
        awaitFileWork(on: sidebar) { sidebar.commitRename("Draft.tex") }
        XCTAssertFalse(sidebar.isRenamingForTesting, "a case-only change is a real rename")
    }

    func testUnchangedNameJustClosesTheEditor() {
        sidebar.beginRename(draft())
        sidebar.commitRename("draft.tex")
        XCTAssertFalse(sidebar.isRenamingForTesting, "no change is a no-op, not an error")
        XCTAssertTrue(exists("draft.tex"))
    }

    // MARK: - Clicking never renames

    /// Round 3 (owner request, 2026-08-18): the click-pause-click gesture is
    /// gone. Rename is reached through the row menu (right-click) or the
    /// keyboard, never by clicking a row twice.
    func testSecondSlowClickOnTheSameRowDoesNotRename() {
        let node = draft()
        sidebar.activate(node)
        sidebar.activate(node)
        XCTAssertFalse(sidebar.isRenamingForTesting,
                       "clicking a row twice opens it twice; it never starts an edit")
    }

    /// The second click is an ordinary activation, not a swallowed one.
    func testSecondSlowClickOpensTheFileAgain() {
        var opened: [URL] = []
        sidebar.onOpenFile = { opened.append($0) }
        let node = draft()
        sidebar.activate(node)
        sidebar.activate(node)
        XCTAssertEqual(opened, [root.appendingPathComponent("draft.tex"),
                                root.appendingPathComponent("draft.tex")])
    }

    // MARK: - Clicking away while a rename is in flight

    /// Owner report: renaming a row and then clicking a DIFFERENT row left BOTH
    /// rows painted as selected. The rename must end first, then the new row
    /// activates.
    func testClickingAnotherRowWhileRenamingEndsTheRename() {
        sidebar.beginRename(draft())
        XCTAssertTrue(sidebar.isRenamingForTesting)
        let other = FileNode(url: root.appendingPathComponent("taken.tex"),
                             name: "taken.tex", isDirectory: false)
        sidebar.activate(other)
        XCTAssertFalse(sidebar.isRenamingForTesting,
                       "tapping another row must close the in-flight rename")
    }

    /// The rename is CANCELLED, not committed: the owner's stated expectation is
    /// "cancel first file title editing instead and select new file".
    func testClickingAnotherRowWhileRenamingDiscardsTheEdit() {
        sidebar.beginRename(draft())
        let other = FileNode(url: root.appendingPathComponent("taken.tex"),
                             name: "taken.tex", isDirectory: false)
        sidebar.activate(other)
        XCTAssertTrue(exists("draft.tex"), "the original name survives")
    }

    /// The whole point of the report: the new row opens.
    func testClickingAnotherRowWhileRenamingStillOpensIt() {
        var opened: [URL] = []
        sidebar.onOpenFile = { opened.append($0) }
        sidebar.beginRename(draft())
        let other = FileNode(url: root.appendingPathComponent("taken.tex"),
                             name: "taken.tex", isDirectory: false)
        sidebar.activate(other)
        XCTAssertEqual(opened, [root.appendingPathComponent("taken.tex")])
    }

    /// Clicking the row that is ALREADY renaming must not cancel it — that is a
    /// click inside the live text field, not a click away.
    func testClickingTheRenamingRowItselfKeepsTheEditorOpen() {
        let node = draft()
        sidebar.beginRename(node)
        sidebar.activate(node)
        XCTAssertTrue(sidebar.isRenamingForTesting)
    }

    /// A single click still opens the file.
    func testClickOpensTheFile() {
        var opened: [URL] = []
        sidebar.onOpenFile = { opened.append($0) }
        sidebar.activate(draft())
        XCTAssertEqual(opened, [root.appendingPathComponent("draft.tex")])
    }
}
