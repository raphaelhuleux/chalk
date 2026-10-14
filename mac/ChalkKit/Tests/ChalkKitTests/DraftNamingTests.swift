import XCTest
@testable import ChalkKit

/// Session-only draft titles: lowest free "Untitled" / "Untitled N", numbers
/// reclaimed when a draft closes (nothing ever consulted on disk).
final class DraftNamingTests: XCTestCase {
    func testFirstDraftIsUntitled() {
        XCTAssertEqual(DraftNaming.nextUntitledTitle(existing: []), "Untitled")
    }

    func testSecondDraftIsUntitled2() {
        XCTAssertEqual(DraftNaming.nextUntitledTitle(existing: ["Untitled"]), "Untitled 2")
    }

    func testThirdDraftIsUntitled3() {
        XCTAssertEqual(DraftNaming.nextUntitledTitle(existing: ["Untitled", "Untitled 2"]),
                       "Untitled 3")
    }

    func testClosedDraftNumberIsReclaimed() {
        // "Untitled" was closed while "Untitled 2" stayed open.
        XCTAssertEqual(DraftNaming.nextUntitledTitle(existing: ["Untitled 2"]), "Untitled")
    }

    func testGapIsFilledBeforeExtending() {
        XCTAssertEqual(DraftNaming.nextUntitledTitle(existing: ["Untitled", "Untitled 3"]),
                       "Untitled 2")
    }

    func testUnrelatedTitlesAreIgnored() {
        XCTAssertEqual(DraftNaming.nextUntitledTitle(existing: ["Notes.md", "Untitled.md"]),
                       "Untitled")
    }
}
