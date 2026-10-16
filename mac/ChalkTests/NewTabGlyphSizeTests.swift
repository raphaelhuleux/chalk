import XCTest
import ChalkKit
@testable import Chalk

/// The tab row's "+" is typography, not a button: Paper draws it as a 13px
/// svg whose arms span 8.5px, next to 12px mono names whose capitals are
/// about 8.4px tall. The glyph must read as one more character in the row,
/// so its ink may not be taller than a capital letter in the label font
/// (with a quarter of slack for SF's rounded caps).
final class NewTabGlyphSizeTests: XCTestCase {
    @MainActor
    func testNewTabGlyphInkIsNoTallerThanALabelCapital() throws {
        let strip = HeaderTabStrip(frame: CGRect(x: 0, y: 0, width: 600, height: 44))
        let image = try XCTUnwrap(strip.newTabGlyphImageForTesting)
        let ink = inkBounds(of: image)
        let cap = NSFont.chalkMono(size: ChalkMetrics.tabFontSize).capHeight
        XCTAssertLessThanOrEqual(
            ink.height, cap * 1.25,
            "+ ink is \(ink) but the label's capitals are \(cap)pt tall")
        XCTAssertLessThanOrEqual(ink.width, cap * 1.25)
    }

    /// The glyph's opaque extent in points, at 4x so sub-point edges count.
    private func inkBounds(of image: NSImage) -> CGSize {
        let scale: CGFloat = 4
        let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return .zero }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.3 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return .zero }
        return CGSize(width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}
