import XCTest
@testable import ChalkKit

/// Naming rules shared by inline rename (a name the user typed) and Duplicate
/// (a name the app invents). Pure, so `swift test` covers them without the
/// app.
final class FileNamingTests: XCTestCase {
    func testAcceptsAPlainNewName() {
        XCTAssertNil(FileNaming.validateRename("notes.md", current: "draft.md"))
    }

    func testRejectsEmptyAndWhitespaceOnly() {
        XCTAssertEqual(FileNaming.validateRename("", current: "a.md"), .empty)
        XCTAssertEqual(FileNaming.validateRename("   ", current: "a.md"), .empty)
    }

    func testRejectsTheUnchangedName() {
        XCTAssertEqual(FileNaming.validateRename("a.md", current: "a.md"), .unchanged)
    }

    func testRejectsPathSeparators() {
        XCTAssertEqual(FileNaming.validateRename("sub/a.md", current: "a.md"), .containsSlash)
    }

    func testRejectsHiddenNames() {
        XCTAssertEqual(FileNaming.validateRename(".hidden", current: "a.md"), .hidden)
    }

    /// A case-only rename is a real rename (`FileMove` allows it through the
    /// collision guard), so validation must not call it "unchanged".
    func testAllowsCaseOnlyRename() {
        XCTAssertNil(FileNaming.validateRename("Notes.md", current: "notes.md"))
    }

    func testUniqueNameCountsUpFromTwo() {
        let taken: Set<String> = ["Untitled.md", "Untitled 2.md"]
        XCTAssertEqual(
            FileNaming.uniqueName(base: "Untitled", ext: "md", isTaken: { taken.contains($0) }),
            "Untitled 3.md")
    }

    func testUniqueNameWithoutExtension() {
        let taken: Set<String> = ["Untitled Folder"]
        XCTAssertEqual(
            FileNaming.uniqueName(base: "Untitled Folder", ext: nil, isTaken: { taken.contains($0) }),
            "Untitled Folder 2")
    }

    func testDuplicateNameKeepsTheExtension() {
        let taken: Set<String> = ["draft.tex"]
        XCTAssertEqual(
            FileNaming.duplicateName(for: "draft.tex", isTaken: { taken.contains($0) }),
            "draft 2.tex")
    }

    func testDuplicateNameSkipsExistingCopies() {
        let taken: Set<String> = ["draft.tex", "draft 2.tex"]
        XCTAssertEqual(
            FileNaming.duplicateName(for: "draft.tex", isTaken: { taken.contains($0) }),
            "draft 3.tex")
    }

    /// Only the LAST dot separates the extension: "notes.v2.md" duplicates as
    /// "notes.v2 2.md", not "notes 2.v2.md".
    func testDuplicateNameWithSeveralDots() {
        XCTAssertEqual(
            FileNaming.duplicateName(for: "notes.v2.md", isTaken: { _ in false }),
            "notes.v2 2.md")
    }

    func testDuplicateNameForAFolder() {
        XCTAssertEqual(
            FileNaming.duplicateName(for: "Papers", isTaken: { _ in false }),
            "Papers 2")
    }

    /// A dotfile has no extension to preserve, so the whole name is the base.
    func testDuplicateNameForADotfile() {
        XCTAssertEqual(
            FileNaming.duplicateName(for: ".gitignore", isTaken: { _ in false }),
            ".gitignore 2")
    }
}
