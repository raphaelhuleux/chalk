import XCTest
@testable import ChalkKit

/// The band arithmetic, checked without a window. The 32-cell
/// `ChromeInvariantMatrixTests` asserts the relationships over live frames and
/// is the real gate; this pins the numbers themselves, for every window mode
/// from one test run.
final class BandLayoutTests: XCTestCase {
    /// Spec-shaped, not the real tokens: the point is the arithmetic.
    private let metrics = BandLayout.Metrics(
        tabStripHeight: 46, tabStripLeading: 78, tabRowDividerGap: 14,
        editorRestingPad: 27)

    private func resolve(
        glue: Bool = true, fullscreen: Bool = false,
        zen: Bool = false, safeAreaTop: CGFloat, lastReal: CGFloat = 44, dividerX: CGFloat = 0
    ) -> BandLayout.Result {
        BandLayout.resolve(glueAvailable: glue, fullscreen: fullscreen,
                           zen: zen, safeAreaTop: safeAreaTop, lastRealBandHeight: lastReal,
                           dividerX: dividerX, metrics: metrics)
    }

    /// Zen reclaims the band's share: the text rests over the system inset
    /// alone, because the band it used to clear is no longer on screen.
    func testZenReclaimsTheBand() {
        XCTAssertEqual(resolve(zen: true, safeAreaTop: 52).editorChromeTopInset, 79)
        // Full screen: the glue hid the system chrome too, so nothing at all
        // reserves and the text rests on the breathing pad alone.
        XCTAssertEqual(
            resolve(fullscreen: true, zen: true, safeAreaTop: 0).editorChromeTopInset, 27)
    }

    /// The chips are bottom-anchored in the band, so a band shorter than the
    /// row pushes their top off the window. Full screen has no useful safe
    /// area and reuses the cached windowed titlebar height.
    func testBandIsFlooredAtTheRowAndFullScreenReusesTheCachedHeight() {
        XCTAssertEqual(resolve(safeAreaTop: 36).bandHeight, 46)
        XCTAssertEqual(resolve(safeAreaTop: 52).bandHeight, 52)
        XCTAssertEqual(resolve(fullscreen: true, safeAreaTop: 0, lastReal: 52).bandHeight, 52)
        // The floor keeps the chips on screen even with a stale small cache.
        XCTAssertEqual(resolve(fullscreen: true, safeAreaTop: 0, lastReal: 36).bandHeight, 46)
    }

    /// A real windowed titlebar reading is remembered for the next full-screen
    /// episode; a transient mid-transition zero is not, and full screen never
    /// records (its safe area is not a titlebar).
    func testOnlyARealWindowedReadingIsRecorded() {
        XCTAssertEqual(resolve(safeAreaTop: 52, lastReal: 44).recordedBandHeight, 52)
        XCTAssertEqual(resolve(safeAreaTop: 0, lastReal: 44).recordedBandHeight, 44)
        XCTAssertEqual(
            resolve(fullscreen: true, safeAreaTop: 99, lastReal: 44).recordedBandHeight, 44)
        // No glue: the app's own band is folded into the safe area, so reading
        // it back would feed the band into itself.
        XCTAssertEqual(resolve(glue: false, safeAreaTop: 52, lastReal: 44)
            .recordedBandHeight, 44)
    }

    /// The band never moves: it spans the whole window so its paint can run
    /// edge to edge, and only the chips take the divider's inset, minus the
    /// row's own gutter (its `tabStripLeading` clears the traffic lights,
    /// which past the divider is the Library's job).
    func testOnlyTheChipsTakeTheDividerInset() {
        XCTAssertEqual(
            resolve(fullscreen: true, safeAreaTop: 0, dividerX: 300).chipLeadingInset,
            300 + 14 - 78)
        // No tiled Library: the chips return to their own gutter.
        XCTAssertEqual(resolve(fullscreen: true, safeAreaTop: 0).chipLeadingInset, 0)
    }

    /// Which chrome is the tab UI: the UIKit band only in full screen, where
    /// the glue hides the system toolbar. The windowed row is the AppKit
    /// titlebar strip, so the band owns nothing.
    func testTheBandOwnsTheTabRowOnlyInFullScreen() {
        XCTAssertFalse(resolve(safeAreaTop: 52).bandOwnsTabRow)
        XCTAssertTrue(resolve(fullscreen: true, safeAreaTop: 0).bandOwnsTabRow)
    }

    /// H-6: with the AppKit bundle missing there is no titlebar strip at all,
    /// so the opaque UIKit band is the tab UI — the editor keeps the old
    /// below-the-band clearance and the stylesheet's own resting padding.
    func testTheNoGlueFallbackClearsTheBandInsteadOfRunningUnderIt() {
        let fallback = resolve(glue: false, safeAreaTop: 52)
        XCTAssertEqual(fallback.editorTopClearance, 52)
        XCTAssertNil(fallback.editorChromeTopInset)
        // Everywhere else the editor runs full-bleed under the chrome.
        XCTAssertEqual(resolve(safeAreaTop: 52).editorTopClearance, 0)
    }
}
