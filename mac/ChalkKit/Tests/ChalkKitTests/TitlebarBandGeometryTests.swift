import XCTest
@testable import ChalkKit

/// The Mac titlebar cover. Pinned here because the AppKit glue that draws it
/// is unreachable from every test target, and because this decision has now
/// been wrong in three different ways — and changed shape once more with Paper
/// (2026-08-24), which made the Library flat and flush: the cut-out reaches the
/// window's leading and top edges and its corners are square.
final class TitlebarBandGeometryTests: XCTestCase {
    private let titlebar = CGRect(x: 0, y: 0, width: 1200, height: 52)
    private let baseline: CGFloat = 6
    private let divider: CGFloat = 431

    private func paint(libraryWidth: CGFloat = 431) -> TitlebarBandGeometry.Paint {
        TitlebarBandGeometry.paint(
            bounds: titlebar, chipBaseline: baseline, libraryWidth: libraryWidth)
    }

    /// Report 1: the paint started at the divider, so the slice above the
    /// sidebar kept the panel colour. The band still spans the window — what
    /// changed with Paper is that the Library's cut-out now reaches the
    /// window's leading and top edges, so the corner beside the traffic lights
    /// belongs to the PANEL rather than to the cover.
    func testTheBandSpansTheWindowAndTheLibraryOwnsItsCorner() {
        let p = paint()
        XCTAssertEqual(p.band.minX, 0, accuracy: 0.5)
        XCTAssertEqual(p.band.width, titlebar.width, accuracy: 0.5)
        XCTAssertFalse(p.paints(CGPoint(x: 3, y: titlebar.maxY - 3)),
                       "the flush panel reaches the window's top-left corner, so the cover stops there")
        let hole = try! XCTUnwrap(p.libraryHole)
        XCTAssertEqual(hole.minX, 0, accuracy: 0.5,
                       "a flush panel leaves no strip of cover down its leading edge")
        XCTAssertEqual(hole.maxY, titlebar.maxY, accuracy: 0.5,
                       "and none across its top")
    }

    /// Report 2: a full-width fill covered the panel, because this paint sits
    /// above the UIKit content.
    func testTheLibraryPanelIsNotPaintedOver() {
        XCTAssertFalse(paint().paints(CGPoint(x: divider / 2, y: titlebar.height / 2)),
                       "the bar passes behind the panel; it must not paint over it")
    }

    /// Report 3 was the corner notch: the hole had to follow the panel's
    /// ROUNDED corners or an unpainted square was left where the panel curved
    /// away. Paper's panel is square, so the rule inverts — the hole's corner
    /// IS the panel, all the way into the angle, and a radius would now be the
    /// defect.
    func testTheSquarePanelOwnsItsCornerCompletely() {
        let p = paint()
        let hole = try! XCTUnwrap(p.libraryHole)
        // A hair inside the top-trailing corner of the hole: panel, not cover.
        XCTAssertFalse(p.paints(CGPoint(x: hole.maxX - 0.5, y: hole.maxY - 0.5)),
                       "the corner belongs to the panel right into the angle")
        XCTAssertFalse(p.paints(CGPoint(x: hole.minX + 0.5, y: hole.maxY - 0.5)))
    }

    /// The hole's own bottom edge must never land inside the visible band, or
    /// a seam appears where the panel leaves the titlebar. (With a radius it
    /// was the bottom CORNERS; square, it is the edge itself, and the margin
    /// has to survive a future radius.)
    func testTheHoleExtendsWellBelowTheBand() {
        let p = paint()
        let hole = try! XCTUnwrap(p.libraryHole)
        XCTAssertLessThan(hole.minY, p.band.minY - 1,
                          "the hole must clear the band's bottom edge")
    }

    func testTheEditorSideIsFullyPainted() {
        let p = paint()
        XCTAssertTrue(p.paints(CGPoint(x: divider + 40, y: baseline + 2)))
        XCTAssertTrue(p.paints(CGPoint(x: titlebar.maxX - 2, y: titlebar.maxY - 2)))
    }

    func testHiddenLibraryGivesOneUninterruptedStrip() {
        let p = paint(libraryWidth: 0)
        XCTAssertNil(p.libraryHole)
        XCTAssertTrue(p.paints(CGPoint(x: 5, y: titlebar.maxY - 5)))
        XCTAssertTrue(p.paints(CGPoint(x: 600, y: titlebar.maxY - 5)))
    }

    /// The sliver below the name row stays the window background. It carries
    /// the same tone as the cover now (Paper paints the paper), so this is
    /// about the SHAPE: nothing is drawn below the row's baseline, which is
    /// what keeps a future cover colour from cutting a line across the paper.
    func testNothingIsPaintedBelowTheChipBaseline() {
        XCTAssertEqual(paint().band.minY, baseline, accuracy: 0.5)
        XCTAssertFalse(paint().paints(CGPoint(x: 900, y: baseline - 2)))
    }

    /// A baseline arriving before the first strip layout, or past the
    /// titlebar's height, must not invert or overflow the band.
    func testDegenerateBaselinesAreClamped() {
        for value in [CGFloat(-40), 0, 999] {
            let p = TitlebarBandGeometry.paint(
                bounds: titlebar, chipBaseline: value, libraryWidth: divider)
            XCTAssertGreaterThanOrEqual(p.band.height, 0)
            XCTAssertLessThanOrEqual(p.band.maxY, titlebar.maxY + 0.5)
        }
    }

    // MARK: - The outline panel's hole (2026-09-05)

    private func paintWithOutline(outlineWidth: CGFloat = 258, libraryWidth: CGFloat = 431) -> TitlebarBandGeometry.Paint {
        TitlebarBandGeometry.paint(
            bounds: titlebar, chipBaseline: baseline, libraryWidth: libraryWidth, outlineWidth: outlineWidth)
    }

    /// The outline panel is the Library's mirror: a full-height column on the
    /// trailing edge that the band must not paint over either.
    func testTheOutlinePanelIsNotPaintedOver() {
        let p = paintWithOutline()
        XCTAssertFalse(p.paints(CGPoint(x: titlebar.maxX - 100, y: titlebar.height / 2)),
                       "the bar passes behind the outline panel; it must not paint over it")
        XCTAssertTrue(p.paints(CGPoint(x: titlebar.maxX - 300, y: titlebar.height / 2)),
                      "the editor's slice beside the panel stays painted")
    }

    func testTheOutlineHoleReachesTheTrailingAndTopEdges() {
        let hole = try! XCTUnwrap(paintWithOutline().outlineHole)
        XCTAssertEqual(hole.maxX, titlebar.maxX, accuracy: 0.5)
        XCTAssertEqual(hole.minX, titlebar.maxX - 258, accuracy: 0.5)
        XCTAssertEqual(hole.maxY, titlebar.maxY, accuracy: 0.5)
        XCTAssertLessThan(hole.minY, titlebar.minY, "extends below the band like the Library's hole")
    }

    func testHiddenOutlineLeavesNoTrailingHole() {
        XCTAssertNil(paintWithOutline(outlineWidth: 0).outlineHole)
        XCTAssertTrue(paintWithOutline(outlineWidth: 0).paints(CGPoint(x: titlebar.maxX - 10, y: titlebar.height / 2)))
    }

    /// Both holes at once: Library on the leading edge, outline on the
    /// trailing edge, the editor's slice between them painted.
    func testBothPanelsAreCutOutTogether() {
        let p = paintWithOutline()
        XCTAssertNotNil(p.libraryHole)
        XCTAssertNotNil(p.outlineHole)
        XCTAssertFalse(p.paints(CGPoint(x: 10, y: titlebar.height / 2)))
        XCTAssertTrue(p.paints(CGPoint(x: 600, y: titlebar.height / 2)))
        XCTAssertFalse(p.paints(CGPoint(x: titlebar.maxX - 10, y: titlebar.height / 2)))
    }

    /// The default keeps every existing caller's paint unchanged.
    func testOutlineWidthDefaultsToNoHole() {
        XCTAssertNil(paint().outlineHole)
    }
}
