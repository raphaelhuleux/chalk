import XCTest
import ChalkKit
@testable import Chalk

/// The row's "+" has to read as a control on its own: an empty row shows nothing else beside the
/// traffic lights. So its ink is held inside a band, never only under a ceiling: at least a
/// label capital and at least the close ×, at most half again a capital so it does not shout
/// over the names (docs/issues/2026-11-16-tab-row-regressions.md).
final class NewTabGlyphSizeTests: XCTestCase {
    @MainActor
    func testNewTabGlyphInkSitsInItsBand() throws {
        let strip = HeaderTabStrip(frame: CGRect(x: 0, y: 0, width: 600, height: 44))
        let plus = try XCTUnwrap(strip.newTabGlyphImageForTesting).inkSizeForTesting
        let close = try XCTUnwrap(HeaderTabStrip.closeGlyphImageForTesting).inkSizeForTesting
        let cap = NSFont.chalkMono(size: ChalkMetrics.tabFontSize).capHeight
        for (axis, ink, closeInk) in [("height", plus.height, close.height), ("width", plus.width, close.width)] {
            XCTAssertGreaterThanOrEqual(ink, cap, "+ ink \(axis) \(ink) is under a capital (\(cap))")
            XCTAssertGreaterThanOrEqual(ink, closeInk, "+ ink \(axis) \(ink) is under the close ×'s \(closeInk)")
            XCTAssertLessThanOrEqual(ink, cap * 1.5, "+ ink \(axis) \(ink) shouts over the names (cap \(cap))")
        }
    }
}
