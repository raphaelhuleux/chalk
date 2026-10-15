import XCTest
import ChalkKit
@testable import ChalkMac

/// Paper's surfaces (2026-08-24): the Library separates from the paper by TONE
/// (Y-2 — panels separate by tone and shadow, and a hairline is never doubled
/// with a shadow), and the tab row's cover is the paper's own colour.
///
/// These are the facts a screenshot would show, stated where a test can fail
/// on them: the audit found the glass panel's ring-plus-shadow doubling by eye,
/// and nothing would have caught it coming back.
@MainActor
final class PaperSurfaceTests: XCTestCase {
    func testTheLibraryPanelIsFlatToneOnTone() {
        let panel = ChalkGlassView(style: .paper, cornerRadius: 0)
        let surface = panel.surfaceForTesting

        XCTAssertFalse(surface.materialShown,
                       "Paper's Library is tone-on-tone: no blur, no tint wash")
        XCTAssertEqual(surface.ringWidth, 0, accuracy: 0.01,
                       "no hairline ring — the tone difference is the edge")
        XCTAssertEqual(surface.shadowOpacity, 0, accuracy: 0.001,
                       "and no shadow to double it with")
        XCTAssertEqual(surface.fill, .chalkChromeBackground,
                       "the chrome tone, in both appearances")
    }

    /// The two floating surfaces keep their glass: they sit OVER live text,
    /// which is the one place blur earns its keep (owner decision 2026-08-24).
    func testThePillAndThePalettesKeepTheirGlass() {
        let pill = ChalkGlassView(style: .glass, cornerRadius: 11, interactive: true)
        XCTAssertTrue(pill.surfaceForTesting.materialShown
                        || pill.surfaceForTesting.fill != nil,
                      "the pill still floats: material, or the light-mode solid that stands in for it")
        XCTAssertGreaterThan(ChalkGlassView.Style.glass.shadowOpacity.dark, 0)
        XCTAssertGreaterThan(ChalkGlassView.Style.palette.shadowOpacity.dark, 0)
    }

    /// The row's cover is invisible by design and still load-bearing: the
    /// editor runs full-bleed underneath, so an editor-toned opaque cover is
    /// what stops scrolled text surfacing between the names.
    func testTheNameRowsCoverIsThePapersOwnTone() {
        let band = HeaderBarView()
        band.frame = CGRect(x: 0, y: 0, width: 800, height: ChalkMetrics.tabStripHeight)
        band.layoutIfNeeded()
        XCTAssertEqual(band.coverFillForTesting, .chalkEditorBackground,
                       "one paper surface from the window edge down — not a darker band")
        XCTAssertEqual(band.paintFrameForTesting.height, band.bounds.height, accuracy: 0.5,
                       "and it covers the whole row, or text surfaces above the names")
    }
}
