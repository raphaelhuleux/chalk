import XCTest
@testable import ChalkKit

final class ChromeLayoutReferenceTests: XCTestCase {
    private func layout() -> ChromeLayout {
        ChromeLayout(
            state: UIState(window: .windowed, sidebar: .shown, mode: .normal, appearance: .light),
            root: CGRect(x: 0, y: 0, width: 1300, height: 910),
            band: CGRect(x: 0, y: 0, width: 1300, height: 57.1),
            bandPaint: CGRect(x: 0, y: 0, width: 1300, height: 57.1),
            bandPaintHole: CGRect(x: 0, y: 0, width: 335, height: 57.1),
            libraryPanel: CGRect(x: 0, y: 0, width: 335, height: 910),
            tabStrip: CGRect(x: 335, y: 10, width: 965, height: 40),
            editorRestingTop: 84.1, restingPad: 27,
            reserveTop: 57.1, safeLeading: 0,
            macStrip: MacStripExpectation(dividerX: 335, visible: true, faded: false),
            outlinePanel: nil)
    }

    func testRecordsDivideEveryLengthByTheScaleExceptTheRestingPad() {
        let record = ChromeLayoutRecord(layout(), scale: 1 / 0.77)
        XCTAssertEqual(record.libraryPanel?.width ?? 0, 335 * 0.77, accuracy: 0.01)
        XCTAssertEqual(record.reserveTop, 57.1 * 0.77, accuracy: 0.01)
        XCTAssertEqual(record.stripDividerX ?? 0, 335 * 0.77, accuracy: 0.01)
        XCTAssertEqual(record.restingPad, 27)
        XCTAssertNil(record.outlinePanel)
    }

    func testReferenceRoundTripsThroughJSONSortedById() throws {
        let b = ChromeLayoutRecord(layout(), scale: 1)
        var a = b
        a.id = "a-cell"
        let reference = ChromeLayoutReference(shell: "catalyst", captured: "2026-10-15", cells: [b, a])
        let data = try reference.encoded()
        let back = try ChromeLayoutReference.decode(data)
        XCTAssertEqual(back, reference)
        XCTAssertEqual(back.cells.map(\.id), ["a-cell", b.id])
        XCTAssertEqual(back.cell("a-cell"), a)
    }
}
