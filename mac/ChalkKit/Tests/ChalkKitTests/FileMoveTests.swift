import XCTest
@testable import ChalkKit

/// U11/U12: the pure path arithmetic behind rename + drag-move open-tab
/// preservation and the drag cycle guard.
final class FileMoveTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Loc", isDirectory: true)

    // MARK: remap (open-tab URL follows the moved file)

    func testRemapRenamedFileExact() {
        let from = root.appendingPathComponent("Welcome.md")
        let to = root.appendingPathComponent("Renamed.md")
        XCTAssertEqual(FileMove.remap(url: from, from: from, to: to)?.standardizedFileURL,
                       to.standardizedFileURL)
    }

    func testRemapDescendantOfRenamedAncestorFolder() {
        // A tab open on /Loc/A/sub/file.md when folder A → B.
        let tab = root.appendingPathComponent("A/sub/file.md")
        let from = root.appendingPathComponent("A")
        let to = root.appendingPathComponent("B")
        XCTAssertEqual(FileMove.remap(url: tab, from: from, to: to)?.standardizedFileURL,
                       root.appendingPathComponent("B/sub/file.md").standardizedFileURL)
    }

    func testRemapUnaffectedURLReturnsNil() {
        let tab = root.appendingPathComponent("A/keep.md")
        let from = root.appendingPathComponent("Other.md")
        let to = root.appendingPathComponent("Other2.md")
        XCTAssertNil(FileMove.remap(url: tab, from: from, to: to))
    }

    func testRemapSiblingPrefixIsNotAMatch() {
        // /Loc/Alpha must not be treated as a child of /Loc/A.
        let tab = root.appendingPathComponent("Alpha/x.md")
        let from = root.appendingPathComponent("A")
        let to = root.appendingPathComponent("B")
        XCTAssertNil(FileMove.remap(url: tab, from: from, to: to))
    }

    // MARK: canMove (drag legality + cycle guard)

    func testCanMoveFileIntoFolder() {
        let file = root.appendingPathComponent("A/note.md")
        let dest = root.appendingPathComponent("B")
        XCTAssertTrue(FileMove.canMove(source: file, isDirectory: false, into: dest))
    }

    func testCanMoveFolderIntoFolder() {
        let folder = root.appendingPathComponent("A")
        let dest = root.appendingPathComponent("B")
        XCTAssertTrue(FileMove.canMove(source: folder, isDirectory: true, into: dest))
    }

    func testRejectNoOpAlreadyInDirectory() {
        let file = root.appendingPathComponent("A/note.md")
        let dest = root.appendingPathComponent("A")
        XCTAssertFalse(FileMove.canMove(source: file, isDirectory: false, into: dest))
    }

    func testRejectFolderIntoItself() {
        let folder = root.appendingPathComponent("A")
        XCTAssertFalse(FileMove.canMove(source: folder, isDirectory: true, into: folder))
    }

    func testRejectFolderIntoOwnDescendant() {
        let folder = root.appendingPathComponent("A")
        let descendant = root.appendingPathComponent("A/sub/deep")
        XCTAssertFalse(FileMove.canMove(source: folder, isDirectory: true, into: descendant))
    }

    func testAllowFileEvenWhenPathPrefixMatches() {
        // A file (not a directory) named like a folder prefix is not cycle-guarded.
        let file = root.appendingPathComponent("A")
        let dest = root.appendingPathComponent("A/sub") // contrived; still a real move
        XCTAssertTrue(FileMove.canMove(source: file, isDirectory: false, into: dest))
    }
}
