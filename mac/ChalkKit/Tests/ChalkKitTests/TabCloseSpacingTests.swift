import XCTest
@testable import ChalkKit

/// The rule's arithmetic. The app's own tokens and measured glyph are checked against it in
/// `TabRowGeometryTests` (ChalkTests), where `ChalkMetrics` lives.
final class TabCloseSpacingTests: XCTestCase {
    private func spacing(innerGap: CGFloat, slot: CGFloat, gap: CGFloat, ink: CGFloat = 8) -> TabCloseSpacing {
        TabCloseSpacing(labelPadding: 8, innerGap: innerGap, slotWidth: slot, tabGap: gap, glyphInkWidth: ink)
    }

    /// The tokens that shipped the defect: a slot widened to 18 with the gap left at 12.
    func testTheWidenedSlotIsRejected() {
        let bad = spacing(innerGap: 8, slot: 18, gap: 12)
        XCTAssertEqual(bad.ownGap, 13)
        XCTAssertEqual(bad.nextGap(reserved: false), 7, "the hover × sat 7pt from the next name")
        XCTAssertEqual(bad.hangingOverrun, 6, "and its slot covered 6pt of the next tab")
        XCTAssertFalse(bad.violations.isEmpty)
    }

    func testASlotThatHugsItsNameIsAccepted() {
        let good = spacing(innerGap: 5, slot: 14, gap: 16)
        XCTAssertEqual(good.ownGap, 8)
        XCTAssertEqual(good.nextGap(reserved: false), 16)
        XCTAssertEqual(good.nextGap(reserved: true), 35)
        XCTAssertLessThanOrEqual(good.hangingOverrun, 0)
        XCTAssertEqual(good.violations, [])
    }

    /// Widening the slot alone must fail, whatever else holds: the drift this rule exists for.
    func testWideningOnlyTheSlotBreaksTheRule() {
        XCTAssertEqual(spacing(innerGap: 5, slot: 14, gap: 16).violations, [])
        XCTAssertFalse(spacing(innerGap: 5, slot: 22, gap: 16).violations.isEmpty)
    }
}
