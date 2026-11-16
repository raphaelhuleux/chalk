import XCTest
@testable import ChalkKit

/// VS Code's editor drop zones (editorDropTarget.ts), less up/down; the tab's own group splits by halves.
final class TabDropPolicyTests: XCTestCase {
    private let size = CGSize(width: 900, height: 600)

    private func zone(_ x: CGFloat, _ y: CGFloat, source: Bool = false, count: Int = 2,
                      canSplit: Bool = true) -> TabDropPolicy.Zone? {
        TabDropPolicy.zone(at: CGPoint(x: x, y: y), in: size, isSourceGroup: source,
                           sourceTabCount: count, canSplit: canSplit)
    }

    func testDeepInsideIsTheGroup() {
        XCTAssertEqual(zone(450, 300), .center)
        XCTAssertEqual(zone(91, 300), .center, "just past the 10% edge band")
        XCTAssertEqual(zone(809, 300), .center)
    }

    func testEdgeBandsSplitTowardTheirThird() {
        XCTAssertEqual(zone(89, 300), .leading)
        XCTAssertEqual(zone(811, 300), .trailing)
        XCTAssertEqual(zone(200, 10), .leading, "top band, leading third")
        XCTAssertEqual(zone(700, 595), .trailing, "bottom band, trailing third")
    }

    func testMiddleThirdOfTheTopAndBottomBandsIsTheGroup() {
        XCTAssertEqual(zone(450, 10), .center)
        XCTAssertEqual(zone(450, 595), .center)
    }

    func testOutsideIsNothing() {
        XCTAssertNil(zone(-1, 300))
        XCTAssertNil(zone(450, 601))
        XCTAssertNil(TabDropPolicy.zone(at: .zero, in: .zero, isSourceGroup: false,
                                        sourceTabCount: 2, canSplit: true))
    }

    func testTheOnlyTabOfItsOwnGroupHasNowhereToGo() {
        XCTAssertNil(zone(10, 300, source: true, count: 1))
        XCTAssertNil(zone(450, 300, source: true, count: 1))
    }

    /// No dead middle: anywhere over its own group shows where the tab will land.
    func testItsOwnGroupSplitsByHalves() {
        XCTAssertEqual(zone(10, 300, source: true, count: 3), .leading)
        XCTAssertEqual(zone(449, 300, source: true, count: 3), .leading)
        XCTAssertEqual(zone(451, 300, source: true, count: 3), .trailing)
        XCTAssertEqual(zone(890, 10, source: true, count: 3), .trailing)
    }

    func testNoRoomForAnotherGroupMakesTheEdgeTheGroup() {
        XCTAssertEqual(zone(10, 300, canSplit: false), .center)
        XCTAssertNil(zone(10, 300, source: true, count: 3, canSplit: false))
    }

    func testOverlayCoversTheNewGroupsHalfOrTheWholeGroup() {
        let bounds = CGRect(x: 100, y: 0, width: 900, height: 600)
        XCTAssertEqual(TabDropPolicy.overlayRect(for: .center, in: bounds), bounds)
        XCTAssertEqual(TabDropPolicy.overlayRect(for: .leading, in: bounds), CGRect(x: 100, y: 0, width: 450, height: 600))
        XCTAssertEqual(TabDropPolicy.overlayRect(for: .trailing, in: bounds), CGRect(x: 550, y: 0, width: 450, height: 600))
    }

    func testInsertionIndexFromAnotherStrip() {
        let mids: [CGFloat] = [50, 150, 250]
        XCTAssertEqual(TabStripPolicy.insertionIndex(probeX: 10, midXs: mids), 0)
        XCTAssertEqual(TabStripPolicy.insertionIndex(probeX: 151, midXs: mids), 2)
        XCTAssertEqual(TabStripPolicy.insertionIndex(probeX: 900, midXs: mids), 3)
        XCTAssertEqual(TabStripPolicy.insertionIndex(probeX: 0, midXs: []), 0)
    }
}
