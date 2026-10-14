import XCTest
@testable import ChalkKit

/// Rules both tab rows (UIKit `HeaderTabStrip`, AppKit `ChalkTabStrip`) run
/// from one definition, plus the one hex decoder both toolkits' colours use.
final class SharedChromeRulesTests: XCTestCase {
    // MARK: - Overflow menu title

    func testMenuTitleIsTheBareNameWithoutAFolder() {
        XCTAssertEqual(TabStripPolicy.menuTitle(name: "notes.md", folder: nil), "notes.md")
    }

    func testMenuTitleCarriesTheFolderPrefixWhenThereIsOne() {
        XCTAssertEqual(TabStripPolicy.menuTitle(name: "notes.md", folder: "draft"),
                       "draft/notes.md",
                       "two tabs sharing a filename must stay distinguishable in the menu")
    }

    // MARK: - Underline slide

    func testUnderlineSlidesOnlyOnAnActiveTabChangeFromAVisibleUnderline() {
        XCTAssertTrue(TabStripPolicy.underlineSlides(wasHidden: false, previousID: "a", newID: "b"))
    }

    func testUnderlineIsPlacedWhenTheActiveTabIsUnchanged() {
        XCTAssertFalse(TabStripPolicy.underlineSlides(wasHidden: false, previousID: "a", newID: "a"),
                       "a rebuild that keeps the active tab must not animate")
    }

    func testUnderlineIsPlacedOnFirstPaint() {
        XCTAssertFalse(TabStripPolicy.underlineSlides(wasHidden: true, previousID: "a", newID: "b"),
                       "an underline coming out of hiding has no old position to slide from")
        XCTAssertFalse(TabStripPolicy.underlineSlides(wasHidden: false, previousID: nil as String?,
                                                      newID: "b"),
                       "no previous tab, nothing to slide from")
    }

    // MARK: - Drag-reorder step

    /// Three items laid out with midpoints at 50, 150, 250.
    private let midXs: [CGFloat] = [50, 150, 250]

    func testReorderStaysPutBetweenItsNeighboursMidpoints() {
        XCTAssertNil(TabStripPolicy.reorderStep(index: 1, probeX: 150, midXs: midXs))
        XCTAssertNil(TabStripPolicy.reorderStep(index: 1, probeX: 50, midXs: midXs),
                     "reaching a midpoint is not crossing it")
        XCTAssertNil(TabStripPolicy.reorderStep(index: 1, probeX: 250, midXs: midXs))
    }

    func testReorderStepsLeftPastThePreviousMidpoint() {
        XCTAssertEqual(TabStripPolicy.reorderStep(index: 1, probeX: 49, midXs: midXs), 0)
    }

    func testReorderStepsRightPastTheNextMidpoint() {
        XCTAssertEqual(TabStripPolicy.reorderStep(index: 1, probeX: 251, midXs: midXs), 2)
    }

    func testReorderNeverStepsPastTheRowEnds() {
        XCTAssertNil(TabStripPolicy.reorderStep(index: 0, probeX: -100, midXs: midXs))
        XCTAssertNil(TabStripPolicy.reorderStep(index: 2, probeX: 1000, midXs: midXs))
        XCTAssertNil(TabStripPolicy.reorderStep(index: 0, probeX: 0, midXs: [50]),
                     "a lone item has nowhere to go")
    }

    /// The callers loop until nil, so a fast drag crosses several items in
    /// one event; the step itself moves one slot at a time.
    func testLoopingTheStepCrossesSeveralItems() {
        // Equal-width items: the slots' midpoints stay put as the items swap.
        var index = 0
        var steps = 0
        while let next = TabStripPolicy.reorderStep(index: index, probeX: 300, midXs: midXs) {
            index = next
            steps += 1
        }
        XCTAssertEqual(index, 2)
        XCTAssertEqual(steps, 2, "one slot per step")
    }

    // MARK: - Hex decoding

    func testRgbDecodesEachChannel() {
        let (red, green, blue) = HexPair.rgb(hex: 0xFF8000)
        XCTAssertEqual(red, 1)
        XCTAssertEqual(green, CGFloat(0x80) / 255)
        XCTAssertEqual(blue, 0)
    }

    func testThemeComponentsAndTheScrimDecodeThroughTheSameRule() {
        let pair = HexPair(dark: 0x1B1A18, light: 0xF8F5EE)
        XCTAssertTrue(pair.components(dark: true) == HexPair.rgb(hex: 0x1B1A18))
        XCTAssertTrue(pair.components(dark: false) == HexPair.rgb(hex: 0xF8F5EE))
        let scrim = ChromeScrim.Components(hex: 0x2C2418, alpha: 0.22)
        XCTAssertTrue((scrim.red, scrim.green, scrim.blue) == HexPair.rgb(hex: 0x2C2418))
    }
}
