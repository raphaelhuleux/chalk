import XCTest
@testable import ChalkKit

/// The rule the Mac tab strip broke on 2026-08-18
/// (docs/issues/2026-08-18-mac-tabs-vanish-when-the-library-is-open.md):
///
/// **A chip the strip decides to SHOW always shows a readable label.** A strip
/// too narrow for its tabs drops the ones that no longer fit into the overflow
/// menu; it never keeps them on screen as blank stubs.
///
/// The AppKit strip used to leave this to Auto Layout: inactive labels carried
/// `.defaultLow` compression resistance with no floor under them, so a crowded
/// strip squeezed every inactive label to ZERO width. Six tabs rendered as one
/// readable chip and five invisible 49pt rectangles, and because the collapse
/// made the row fit, the overflow chevron that was supposed to be the escape
/// hatch never appeared either. Owner report: "the tabs are not aligned with
/// the sidebar" — the visible tab had drifted ~200pt right of the divider.
///
/// The decision now lives here, as arithmetic, so it is testable from the
/// command line instead of being an emergent property of constraint
/// priorities in a bundle no test target can reach.
final class TabStripFitTests: XCTestCase {
    /// Chip naturals used throughout: five ordinary tabs plus one wide active.
    private let naturals: [CGFloat] = [179, 165, 172, 168, 265, 158]

    // MARK: - The gaps between the names

    /// Paper's row separates names by 12pt. Planning as if they touched is
    /// how the 12-tab Mac strip came to hang its active name and its chevron
    /// off the right edge of the window: ten names carry nine gaps, and 108pt
    /// of row that the planner never knew it had spent.
    func testTheGapsBetweenNamesAreRoomTheRowHasAlreadySpent() {
        let six = [CGFloat](repeating: 100, count: 6)
        // 600pt of names, 5 gaps of 12 = 660 needed; the row has 620.
        let flush = TabStripFit.plan(naturalWidths: six, activeIndex: 0, available: 620)
        let spaced = TabStripFit.plan(
            naturalWidths: six, activeIndex: 0, available: 620, spacing: 12)

        XCTAssertEqual(flush.visibleCount, 6, "600pt of names fits 620pt of row")
        XCTAssertEqual(
            spaced.widths.enumerated().filter { spaced.isVisible($0.offset) }
                .reduce(CGFloat(0)) { $0 + $1.element } + 12 * CGFloat(spaced.visibleCount - 1),
            620, accuracy: 0.5,
            "names plus gaps must land inside the row, not past its edge")
    }

    /// The narrow case: when the gaps alone push the row over, a tab leaves
    /// and takes its gap with it, rather than every name shrinking below the
    /// readable floor.
    func testATabThatLeavesTakesItsGapWithIt() {
        let five = [CGFloat](repeating: 90, count: 5)
        let plan = TabStripFit.plan(
            naturalWidths: five, activeIndex: 0, available: 300, spacing: 12)

        let used = plan.widths.enumerated().filter { plan.isVisible($0.offset) }
            .reduce(CGFloat(0)) { $0 + $1.element }
            + 12 * CGFloat(plan.visibleCount - 1)
        XCTAssertLessThanOrEqual(used, 300.5, "the visible row fits, gaps included")
        for index in five.indices where plan.isVisible(index) {
            XCTAssertGreaterThanOrEqual(plan.widths[index], TabStripFit.minimumTabWidth - 0.5)
        }
        XCTAssertTrue(plan.showsOverflow)
    }

    // MARK: - The regression

    func testACrowdedStripNeverShowsAChipWithoutItsLabel() {
        let plan = TabStripFit.plan(
            naturalWidths: naturals, activeIndex: 4, available: 813)

        for (index, width) in plan.widths.enumerated() where plan.isVisible(index) {
            XCTAssertGreaterThanOrEqual(
                width, TabStripFit.minimumTabWidth - 0.5,
                "chip \(index) is on screen at \(width)pt — below the readable floor it is a blank stub")
        }
    }

    func testChipsThatCannotFitGoToTheOverflowMenuInsteadOfCollapsing() {
        let plan = TabStripFit.plan(
            naturalWidths: naturals, activeIndex: 4, available: 300)

        XCTAssertLessThan(plan.visibleCount, naturals.count,
                          "300pt cannot hold six chips; the ones that do not fit must be dropped")
        XCTAssertTrue(plan.showsOverflow,
                      "a dropped tab is only reachable through the chevron menu, so it must be shown")
        for index in 0..<naturals.count where plan.isVisible(index) {
            XCTAssertGreaterThanOrEqual(plan.widths[index], TabStripFit.minimumTabWidth - 0.5)
        }
    }

    func testTheActiveTabIsNeverTheOneDropped() {
        // Narrow enough that only a couple of chips survive; the active tab is
        // last in the row, the position a naive leading-first drop would cut.
        let plan = TabStripFit.plan(
            naturalWidths: naturals, activeIndex: 5, available: 260)

        XCTAssertTrue(plan.isVisible(5),
                      "the tab you are editing must stay on screen at any width")
    }

    // MARK: - The uncrowded cases stay exactly as they were

    func testEverythingFitsAtItsNaturalWidthWhenThereIsRoom() {
        let plan = TabStripFit.plan(
            naturalWidths: naturals, activeIndex: 4, available: 2000)

        XCTAssertEqual(plan.widths, naturals, "no squeeze, no rounding: the naturals pass through")
        XCTAssertEqual(plan.visibleCount, naturals.count)
        XCTAssertFalse(plan.showsOverflow, "nothing is hidden, so the chevron stays away")
    }

    func testAShortNameIsNeverPaddedOutToTheFloor() {
        // "a.md" is narrower than the minimum. The floor is a limit on
        // SQUEEZING, not a minimum size — padding it out would leave a chip
        // with a pool of dead space beside a four-character name.
        let plan = TabStripFit.plan(
            naturalWidths: [70, 179, 172], activeIndex: 0, available: 300)

        XCTAssertEqual(plan.widths[0], 70, accuracy: 0.5,
                       "a chip narrower than the floor keeps its natural width")
    }

    // MARK: - Who yields first

    func testInactiveChipsYieldBeforeTheActiveOne() {
        let plan = TabStripFit.plan(
            naturalWidths: naturals, activeIndex: 4, available: 813)

        XCTAssertEqual(plan.widths[4], 265, accuracy: 0.5,
                       "the active tab keeps its natural width while any inactive one can still yield")
        XCTAssertLessThan(plan.widths[0], naturals[0],
                          "the inactive chips absorb the squeeze")
    }

    func testTheActiveChipYieldsOnlyAfterEveryOtherChipIsAtTheFloor() {
        let plan = TabStripFit.plan(
            naturalWidths: [179, 165, 265], activeIndex: 2, available: 320)

        XCTAssertEqual(plan.widths[0], TabStripFit.minimumTabWidth, accuracy: 0.5)
        XCTAssertEqual(plan.widths[1], TabStripFit.minimumTabWidth, accuracy: 0.5)
        XCTAssertLessThan(plan.widths[2], 265,
                          "with the others already at the floor, the active chip is the only slack left")
        XCTAssertGreaterThanOrEqual(plan.widths[2], TabStripFit.minimumTabWidth - 0.5,
                                    "and it stops at the same floor")
    }

    func testTheSqueezeIsSpreadAcrossTheInactiveChipsNotDumpedOnTheFirst() {
        let plan = TabStripFit.plan(
            naturalWidths: [179, 179, 179, 265], activeIndex: 3, available: 700)

        // 802 natural vs 700 available: 102pt to find across three equal chips.
        for index in 0..<3 {
            XCTAssertEqual(plan.widths[index], 145, accuracy: 1.5,
                           "equal chips give up equal shares")
        }
    }

    // MARK: - Degenerate inputs the strip really can hand us

    func testNoTabsPlansNothing() {
        let plan = TabStripFit.plan(naturalWidths: [], activeIndex: nil, available: 800)

        XCTAssertTrue(plan.widths.isEmpty)
        XCTAssertEqual(plan.visibleCount, 0)
        XCTAssertFalse(plan.showsOverflow)
    }

    func testAStripWithNoRoomAtAllStillShowsTheActiveTab() {
        // First layout pass, before the titlebar has a width: `available` can
        // arrive at 0 or negative. Dropping every chip there would blank the
        // strip on every window resize that passes through zero.
        let plan = TabStripFit.plan(naturalWidths: naturals, activeIndex: 2, available: 0)

        XCTAssertEqual(plan.visibleCount, 1)
        XCTAssertTrue(plan.isVisible(2))
        XCTAssertTrue(plan.showsOverflow)
    }

    func testAnOutOfRangeActiveIndexIsIgnoredRatherThanTrapped() {
        // The strip applies the tab model and the active flag through separate
        // messages; a stale index must not crash the titlebar.
        let plan = TabStripFit.plan(naturalWidths: naturals, activeIndex: 99, available: 813)

        XCTAssertEqual(plan.widths.count, naturals.count)
        for (index, width) in plan.widths.enumerated() where plan.isVisible(index) {
            XCTAssertGreaterThanOrEqual(width, TabStripFit.minimumTabWidth - 0.5)
        }
    }

    // MARK: - Monotonicity: the property that keeps this honest

    /// Widening the strip must never take a tab away. This is the property
    /// that stops tabs flickering in and out while the window is dragged, and
    /// it is the one a "just drop the last chip" planner gets wrong.
    ///
    /// Per-chip width is deliberately NOT asserted across the whole range:
    /// the point where a hidden chip returns is exactly the point where its
    /// neighbours must give up width to make room, so widths legitimately dip
    /// there. Monotonic width is asserted below, inside a fixed visible set.
    func testWideningTheStripNeverTakesATabAway() {
        var previous = TabStripFit.plan(naturalWidths: naturals, activeIndex: 4, available: 0)
        for available in stride(from: CGFloat(5), through: 1400, by: 5) {
            let plan = TabStripFit.plan(
                naturalWidths: naturals, activeIndex: 4, available: available)
            XCTAssertGreaterThanOrEqual(
                plan.visibleCount, previous.visibleCount,
                "a wider strip dropped a tab it used to show (at \(available)pt)")
            XCTAssertTrue(previous.hidden.isSuperset(of: plan.hidden),
                          "a wider strip hid a tab that was visible when it was narrower (at \(available)pt)")
            previous = plan
        }
    }

    func testWideningTheStripGrowsEveryChipWhileTheSameTabsAreShown() {
        // 700...1400 keeps all six visible (floors total 630), so this range
        // isolates width behaviour from the hide/show boundary.
        var previous = TabStripFit.plan(naturalWidths: naturals, activeIndex: 4, available: 700)
        for available in stride(from: CGFloat(710), through: 1400, by: 10) {
            let plan = TabStripFit.plan(
                naturalWidths: naturals, activeIndex: 4, available: available)
            XCTAssertEqual(plan.visibleCount, naturals.count, "precondition: nothing hidden")
            for index in naturals.indices {
                XCTAssertGreaterThanOrEqual(
                    plan.widths[index], previous.widths[index] - 0.5,
                    "chip \(index) shrank as the strip grew (at \(available)pt)")
            }
            previous = plan
        }
    }

    func testNoPlanEverExceedsTheSpaceItWasGiven() {
        for available in stride(from: CGFloat(0), through: 1400, by: 7) {
            let plan = TabStripFit.plan(
                naturalWidths: naturals, activeIndex: 4, available: available)
            let used = plan.widths.enumerated()
                .filter { plan.isVisible($0.offset) }
                .reduce(CGFloat(0)) { $0 + $1.element }
            // One visible chip is always kept, even when it does not fit.
            guard plan.visibleCount > 1 else { continue }
            XCTAssertLessThanOrEqual(used, available + 0.5,
                                     "the planned row overflows its strip at \(available)pt")
        }
    }
}
