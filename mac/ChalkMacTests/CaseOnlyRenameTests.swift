import XCTest
import ChalkKit
@testable import ChalkMac

/// M-10: the sidebar's move/rename collision guard must let a case-only
/// rename through. On case-insensitive APFS, `fileExists` for "Notes.md"
/// matches the source "notes.md" itself, so without the exception every
/// case-only rename was silently rejected.
final class CaseOnlyRenameTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testSameDirCaseOnlyRenameIsAllowed() {
        XCTAssertTrue(SidebarViewController.isCaseOnlyRename(
            from: url("/tmp/dir/notes.md"), to: url("/tmp/dir/Notes.md")))
        XCTAssertTrue(SidebarViewController.isCaseOnlyRename(
            from: url("/tmp/dir/README.md"), to: url("/tmp/dir/readme.md")))
    }

    func testIdenticalNameIsNotCaseOnly() {
        // Same name entirely: nothing to rename; the guard must not treat an
        // actual self-collision as allowed.
        XCTAssertFalse(SidebarViewController.isCaseOnlyRename(
            from: url("/tmp/dir/notes.md"), to: url("/tmp/dir/notes.md")))
    }

    func testDifferentNameIsNotCaseOnly() {
        XCTAssertFalse(SidebarViewController.isCaseOnlyRename(
            from: url("/tmp/dir/notes.md"), to: url("/tmp/dir/other.md")))
        // Case change PLUS letter change is a real collision candidate.
        XCTAssertFalse(SidebarViewController.isCaseOnlyRename(
            from: url("/tmp/dir/notes.md"), to: url("/tmp/dir/Notes2.md")))
    }

    func testSameNameDifferentDirectoryIsNotCaseOnly() {
        // A drag-move to another folder whose file differs only by case IS a
        // real collision there; it must stay rejected.
        XCTAssertFalse(SidebarViewController.isCaseOnlyRename(
            from: url("/tmp/dir/notes.md"), to: url("/tmp/other/Notes.md")))
    }

    func testFolderCaseOnlyRenameIsAllowed() {
        XCTAssertTrue(SidebarViewController.isCaseOnlyRename(
            from: url("/tmp/dir/drafts"), to: url("/tmp/dir/Drafts")))
    }
}
