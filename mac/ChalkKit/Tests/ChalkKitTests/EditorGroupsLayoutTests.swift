import XCTest
@testable import ChalkKit

final class EditorGroupsLayoutTests: XCTestCase {
    func testSharesPlaceTheSeams() {
        XCTAssertEqual(EditorGroupsLayout.even(2).widths(columnWidth: 1000, minimum: 320), [500, 500])
        XCTAssertEqual(EditorGroupsLayout(fractions: [0.4, 0.6]).widths(columnWidth: 1000, minimum: 320), [400, 600])
        XCTAssertEqual(EditorGroupsLayout.single.widths(columnWidth: 777.5, minimum: 320), [777.5])
    }

    func testEachGroupKeepsItsFloor() {
        let widths = EditorGroupsLayout(fractions: [0.1, 0.45, 0.45]).widths(columnWidth: 1200, minimum: 320)
        XCTAssertEqual(widths[0], 320)
        XCTAssertEqual(widths.reduce(0, +), 1200)
        XCTAssertTrue(widths.allSatisfy { $0 >= 320 })
        XCTAssertEqual(widths[1], widths[2], accuracy: 1, "the rest keep their proportion")
    }

    func testNarrowColumnSplitsEvenly() {
        XCTAssertEqual(EditorGroupsLayout(fractions: [0.8, 0.2]).widths(columnWidth: 501, minimum: 320), [250, 251])
    }

    func testWholePointsSumToTheColumn() {
        let widths = EditorGroupsLayout(fractions: [0.37, 0.21, 0.42]).widths(columnWidth: 997.5, minimum: 100)
        XCTAssertEqual(widths.dropLast(), widths.dropLast().map { $0.rounded() })
        XCTAssertEqual(widths.reduce(0, +), 997.5)
    }

    func testEmptyColumn() {
        XCTAssertEqual(EditorGroupsLayout.even(2).widths(columnWidth: 0, minimum: 320), [0, 0])
    }

    func testBadSharesAreRepaired() {
        XCTAssertEqual(EditorGroupsLayout(fractions: [.nan, 1]).fractions, [0.5, 0.5])
        XCTAssertEqual(EditorGroupsLayout(fractions: [-3, .infinity]).fractions, [0.5, 0.5])
        XCTAssertEqual(EditorGroupsLayout(fractions: []).fractions, [1])
        XCTAssertEqual(EditorGroupsLayout(fractions: [2, 6]).fractions, [0.25, 0.75])
    }

    func testSplittingHalvesTheTargetOnly() {
        let layout = EditorGroupsLayout(fractions: [0.5, 0.5]).inserting(at: 2, splitting: 1)
        XCTAssertEqual(layout.fractions, [0.5, 0.25, 0.25])
        XCTAssertEqual(EditorGroupsLayout.single.inserting(at: 0, splitting: 0).fractions, [0.5, 0.5])
    }

    func testRemovingGivesTheShareToTheLeadingNeighbour() {
        XCTAssertEqual(EditorGroupsLayout(fractions: [0.5, 0.25, 0.25]).removing(at: 2).fractions, [0.5, 0.5])
        XCTAssertEqual(EditorGroupsLayout(fractions: [0.2, 0.3, 0.5]).removing(at: 0).fractions, [0.5, 0.5])
        XCTAssertEqual(EditorGroupsLayout.single.removing(at: 0), .single)
    }

    func testCanInsertNeedsRoomForEveryFloor() {
        XCTAssertTrue(EditorGroupsLayout.single.canInsert(columnWidth: 640, minimum: 320))
        XCTAssertFalse(EditorGroupsLayout.even(2).canInsert(columnWidth: 959, minimum: 320))
    }

    func testSeamDragMovesOnlyItsTwoGroups() {
        let layout = EditorGroupsLayout.resized(startWidths: [400, 400, 400], seam: 1, by: 50, minimum: 320)
        XCTAssertEqual(layout.widths(columnWidth: 1200, minimum: 320), [400, 450, 350].map { CGFloat($0) })
    }

    func testSeamDragStopsAtTheFloor() {
        let layout = EditorGroupsLayout.resized(startWidths: [500, 500], seam: 0, by: 400, minimum: 320)
        XCTAssertEqual(layout.widths(columnWidth: 1000, minimum: 320), [680, 320])
    }

    func testFittingKeepsAMatchingLayoutAndEvensAnyOther() {
        let layout = EditorGroupsLayout(fractions: [0.6, 0.4])
        XCTAssertEqual(layout.fitted(toCount: 2), layout)
        XCTAssertEqual(layout.fitted(toCount: 3), .even(3))
    }
}
