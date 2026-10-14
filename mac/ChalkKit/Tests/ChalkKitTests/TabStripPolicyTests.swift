import XCTest
@testable import ChalkKit

/// The tab name row's anatomy rules (Paper, 2026-08-24). They live in ChalkKit
/// because both strips read them: the UIKit `HeaderTabStrip` through the
/// module, and the AppKit `ChalkTabStrip` through the same file compiled into
/// the glue bundle. It used to keep a hand-synced `StripPolicy` copy instead.
final class TabStripPolicyTests: XCTestCase {
    // MARK: - Slot: dot and close are mutually exclusive, dot wins

    func testSlotShowsDotExactlyWhenDirty() {
        XCTAssertEqual(TabStripPolicy.slotContent(isDirty: true), .dot,
                       "an unsaved tab's slot is the dot — never dot AND close")
        XCTAssertEqual(TabStripPolicy.slotContent(isDirty: false), .close)
    }

    // MARK: - The slot takes layout space only where something rests in it

    /// The row's rhythm is the artboard's: name, gap, name. A slot reserved on
    /// every tab would spend 22pt after each one on a mark that is not there,
    /// so it is reserved exactly where something rests in it.
    func testTheSlotIsReservedForTheActiveTabAndForUnsavedWork() {
        XCTAssertTrue(TabStripPolicy.slotIsReserved(isActive: true, isDirty: false),
                      "the active tab rests with a visible ×")
        XCTAssertTrue(TabStripPolicy.slotIsReserved(isActive: true, isDirty: true))
        XCTAssertTrue(TabStripPolicy.slotIsReserved(isActive: false, isDirty: true),
                      "a background tab with unsaved work must still show its dot at rest")
        XCTAssertFalse(TabStripPolicy.slotIsReserved(isActive: false, isDirty: false),
                       "a clean background tab ends at its label; its × hangs in the gap on hover")
    }

    // MARK: - Folder prefix: earned, not automatic

    func testFolderPrefixIsTheImmediateParentName() {
        XCTAssertEqual(
            TabStripPolicy.folderPrefix(
                for: URL(fileURLWithPath: "/Users/r/notes/test-docs/least-squares.md")),
            "test-docs")
    }

    func testFolderPrefixIsNilAtTheRoot() {
        XCTAssertNil(TabStripPolicy.folderPrefix(for: URL(fileURLWithPath: "/file.md")),
                     "a root-level file has no folder worth naming")
        XCTAssertNil(TabStripPolicy.folderPrefix(for: URL(fileURLWithPath: "/")))
    }

    /// The artboard's row is filenames. A prefix on every tab spends the row
    /// on the part neighbours share ("AuditFixtures/" five times over), so it
    /// shows only where the name alone is ambiguous.
    func testOnlyCollidingFilenamesCarryTheFolderPrefix() {
        XCTAssertEqual(
            TabStripPolicy.needsFolderPrefix(names: ["alpha.md", "beta.md", "gamma.tex"]),
            [false, false, false],
            "distinct names say everything a prefix would")
        XCTAssertEqual(
            TabStripPolicy.needsFolderPrefix(names: ["notes.md", "beta.md", "notes.md"]),
            [true, false, true],
            "both sides of a collision need the prefix; nothing else does")
        XCTAssertEqual(TabStripPolicy.needsFolderPrefix(names: []), [])
        XCTAssertEqual(
            TabStripPolicy.needsFolderPrefix(names: ["a.md", "a.md", "a.md"]),
            [true, true, true])
    }

    // MARK: - The slant: one cue per state

    func testTheActiveTabIsTheOnlyOneThatSlants() {
        // `isPreview` is true of EVERY uncommitted file-backed tab, but only
        // the ACTIVE one is ever replaced by a browse click — slanting them
        // all made a twelve-tab row read entirely italic while distinguishing
        // nothing (audit PA-8).
        XCTAssertTrue(TabStripPolicy.isOblique(isActive: true, isPreview: true))
        XCTAssertFalse(TabStripPolicy.isOblique(isActive: false, isPreview: true),
                       "a background preview is not the tab a click replaces, so it must not claim to be")
        XCTAssertFalse(TabStripPolicy.isOblique(isActive: true, isPreview: false))
        XCTAssertFalse(TabStripPolicy.isOblique(isActive: false, isPreview: false))
    }

}
