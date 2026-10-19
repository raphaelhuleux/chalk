import XCTest
@testable import ChalkKit

final class SplitLayoutTests: XCTestCase {
    func testFractionPlacesTheSeam() {
        XCTAssertEqual(SplitLayout.leadingWidth(columnWidth: 1000, fraction: 0.5, minimumPane: 320), 500)
        XCTAssertEqual(SplitLayout.leadingWidth(columnWidth: 1000, fraction: 0.4, minimumPane: 320), 400)
    }

    func testEachPaneKeepsItsFloor() {
        XCTAssertEqual(SplitLayout.leadingWidth(columnWidth: 1000, fraction: 0.2, minimumPane: 320), 320)
        XCTAssertEqual(SplitLayout.leadingWidth(columnWidth: 1000, fraction: 0.8, minimumPane: 320), 680)
    }

    func testNarrowColumnSplitsInHalves() {
        XCTAssertEqual(SplitLayout.leadingWidth(columnWidth: 501, fraction: 0.8, minimumPane: 320), 250)
    }

    func testWholePoints() {
        let width = SplitLayout.leadingWidth(columnWidth: 997, fraction: 0.37, minimumPane: 100)
        XCTAssertEqual(width, width.rounded())
    }

    func testEmptyColumn() {
        XCTAssertEqual(SplitLayout.leadingWidth(columnWidth: 0, fraction: 0.5, minimumPane: 320), 0)
    }

    func testBadFractionsAreClamped() {
        XCTAssertEqual(SplitLayout.clampedFraction(.nan), 0.5)
        XCTAssertEqual(SplitLayout.clampedFraction(.infinity), 0.5)
        XCTAssertEqual(SplitLayout.clampedFraction(-3), 0.1)
        XCTAssertEqual(SplitLayout.clampedFraction(7), 0.9)
    }
}
