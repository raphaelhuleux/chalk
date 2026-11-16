import XCTest
@testable import ChalkKit

final class OutlineFoldingTests: XCTestCase {
    // 0 Intro / 1 Setup / 2 Req / 3 Theorem (callout) / 4 Method / 5 Results
    private let indents = [0, 1, 2, 3, 1, 0]

    func testOnlyRowsWithDeeperNextItemFold() {
        XCTAssertEqual(OutlineFolding.foldable(indents: indents),
                       [true, true, true, false, false, false])
    }

    func testNothingFoldedShowsEverything() {
        XCTAssertEqual(OutlineFolding.visibleIndices(indents: indents, folded: []), [0, 1, 2, 3, 4, 5])
    }

    func testFoldHidesTheSubtreeUpToTheNextSibling() {
        XCTAssertEqual(OutlineFolding.visibleIndices(indents: indents, folded: [1]), [0, 1, 4, 5])
        XCTAssertEqual(OutlineFolding.visibleIndices(indents: indents, folded: [0]), [0, 5])
    }

    func testAFoldInsideAFoldStaysHiddenAndReturnsOnUnfold() {
        XCTAssertEqual(OutlineFolding.visibleIndices(indents: indents, folded: [0, 2]), [0, 5])
        XCTAssertEqual(OutlineFolding.visibleIndices(indents: indents, folded: [2]), [0, 1, 2, 4, 5])
    }

    func testAHiddenItemMapsToItsFoldedAncestorsRow() {
        let visible = OutlineFolding.visibleIndices(indents: indents, folded: [1])
        XCTAssertEqual(OutlineFolding.row(for: 3, visible: visible), 1, "the caret in Theorem selects Setup")
        XCTAssertEqual(OutlineFolding.row(for: 4, visible: visible), 2)
    }

    func testSubtree() {
        XCTAssertEqual(OutlineFolding.subtree(of: 1, indents: indents), [1, 2, 3])
        XCTAssertEqual(OutlineFolding.subtree(of: 5, indents: indents), [5])
    }

    func testKeysIgnoreLinesAndNumberRepeats() {
        func h(_ title: String, _ line: Int) -> OutlineItem {
            OutlineItem(kind: .heading, level: 2, title: title, line: line, calloutType: nil, number: nil)
        }
        let before = OutlineFolding.keys(for: [h("Proof", 3), h("Proof", 9)])
        let after = OutlineFolding.keys(for: [h("Proof", 5), h("Proof", 11)])
        XCTAssertEqual(before, after, "typing above a section keeps its key")
        XCTAssertNotEqual(before[0], before[1], "repeated titles fold independently")
    }
}
