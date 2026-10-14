import XCTest
@testable import ChalkKit

/// Pure outline-palette decisions (preselection, search keys, indentation),
/// kept out of the view controller so they run without a GUI — the
/// SceneRouting doctrine.
final class OutlinePalettePolicyTests: XCTestCase {
    private func heading(_ level: Int, _ title: String, line: Int) -> OutlineItem {
        OutlineItem(kind: .heading, level: level, title: title, line: line,
                    calloutType: nil, number: nil)
    }

    private func callout(_ type: String, _ title: String, line: Int, number: Int) -> OutlineItem {
        OutlineItem(kind: .callout, level: 0, title: title, line: line,
                    calloutType: type, number: number)
    }

    private func figure(_ title: String, line: Int, number: Int) -> OutlineItem {
        OutlineItem(kind: .figure, level: 0, title: title, line: line,
                    calloutType: nil, number: number)
    }

    // MARK: - Preselection

    func testPreselectsLastItemAtOrBeforeCursor() {
        let items = [heading(1, "A", line: 1), heading(2, "B", line: 5), heading(2, "C", line: 9)]
        XCTAssertEqual(OutlinePalettePolicy.preselectedIndex(items: items, cursorLine: 5), 1)
        XCTAssertEqual(OutlinePalettePolicy.preselectedIndex(items: items, cursorLine: 7), 1)
        XCTAssertEqual(OutlinePalettePolicy.preselectedIndex(items: items, cursorLine: 100), 2)
    }

    func testPreselectsFirstItemWhenCursorIsBeforeAll() {
        let items = [heading(1, "A", line: 4)]
        XCTAssertEqual(OutlinePalettePolicy.preselectedIndex(items: items, cursorLine: 2), 0)
    }

    func testPreselectionOnEmptyListIsZero() {
        XCTAssertEqual(OutlinePalettePolicy.preselectedIndex(items: [], cursorLine: 10), 0)
    }

    // MARK: - Search keys and filtering

    func testSearchKeyComposesKindNumberAndTitle() {
        XCTAssertEqual(
            OutlinePalettePolicy.searchKey(callout("theorem", "Pythagoras", line: 3, number: 3)),
            "Theorem 3 Pythagoras")
        // The search key spells out "Figure" (unlike the display badge "Fig. 2")
        // so typing the full word still matches.
        XCTAssertEqual(
            OutlinePalettePolicy.searchKey(figure("convergence", line: 7, number: 2)),
            "Figure 2 convergence")
        XCTAssertEqual(OutlinePalettePolicy.searchKey(heading(2, "Background", line: 1)),
                       "Background")
    }

    func testFilterMatchesByKindWord() {
        let items = [
            heading(1, "Theory of things", line: 1),
            callout("theorem", "Pythagoras", line: 3, number: 1),
            figure("plot", line: 7, number: 1),
        ]
        let hits = OutlinePalettePolicy.filter(query: "figure", items: items)
        XCTAssertEqual(hits.map(\.line), [7])
    }

    func testFilterEmptyQueryReturnsAllInOrder() {
        let items = [heading(1, "A", line: 1), heading(2, "B", line: 5)]
        XCTAssertEqual(OutlinePalettePolicy.filter(query: "", items: items).map(\.line), [1, 5])
    }

    // MARK: - Indentation

    func testHeadingIndentIsNormalizedToMinimumLevel() {
        // A .tex article: \section (level 3) is the top of THIS document, so it
        // must indent 0, not 2.
        let items = [heading(3, "Intro", line: 1), heading(4, "Detail", line: 5)]
        XCTAssertEqual(OutlinePalettePolicy.indentLevels(for: items), [0, 1])
    }

    func testCalloutsAndFiguresIndentOneStepUnderPrecedingHeading() {
        let items = [
            heading(1, "Top", line: 1),
            heading(2, "Section", line: 3),
            callout("definition", "", line: 5, number: 1),
            figure("plot", line: 9, number: 1),
        ]
        XCTAssertEqual(OutlinePalettePolicy.indentLevels(for: items), [0, 1, 2, 2])
    }

    func testItemsBeforeAnyHeadingIndentZero() {
        let items = [figure("early", line: 1, number: 1), heading(1, "Top", line: 5)]
        XCTAssertEqual(OutlinePalettePolicy.indentLevels(for: items), [0, 0])
    }
}

/// Beamer slides must be findable by kind in the palette, the same way
/// "theorem" and "figure" already are.
extension OutlinePalettePolicyTests {
    func testFramesAreSearchableByKindAndNumber() {
        let items = [
            OutlineItem(kind: .heading, level: 3, title: "Estimation", line: 1,
                        calloutType: nil, number: nil),
            OutlineItem(kind: .frame, level: 0, title: "Bayesian updating", line: 4,
                        calloutType: nil, number: 3),
        ]
        XCTAssertEqual(
            OutlinePalettePolicy.searchKey(items[1]),
            "Slide 3 Bayesian updating")
        XCTAssertEqual(
            OutlinePalettePolicy.filter(query: "slide", items: items).map(\.title),
            ["Bayesian updating"])
    }

    func testTitlelessFrameStillCarriesItsSlideLabel() {
        let bare = OutlineItem(kind: .frame, level: 0, title: "", line: 2,
                               calloutType: nil, number: 1)
        XCTAssertEqual(OutlinePalettePolicy.searchKey(bare), "Slide 1")
    }
}
