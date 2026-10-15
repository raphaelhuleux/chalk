import XCTest
import ChalkKit
@testable import Chalk

/// The tab row's "+" is typography, not a button: Paper draws it as a 13px
/// svg whose arms span 8.5px, next to 12px mono names whose capitals are
/// about 8.4px tall. The glyph must read as one more character in the row,
/// so its ink may not be taller than a capital letter in the label font
/// (with a quarter of slack for SF's rounded caps).
final class NewTabGlyphSizeTests: XCTestCase {
    func testNewTabGlyphInkIsNoTallerThanALabelCapital() throws {
        let strip = HeaderTabStrip(frame: CGRect(x: 0, y: 0, width: 600, height: 44))
        let image = try XCTUnwrap(strip.newTabGlyphImageForTesting)
        let ink = inkBounds(of: image)
        let cap = UIFont.chalkMono(size: ChalkMetrics.tabFontSize).capHeight
        XCTAssertLessThanOrEqual(
            ink.height, cap * 1.25,
            "+ ink is \(ink) but the label's capitals are \(cap)pt tall")
        XCTAssertLessThanOrEqual(ink.width, cap * 1.25)
    }

    /// The glyph's opaque extent in points, at 4x so sub-point edges count.
    private func inkBounds(of image: UIImage) -> CGSize {
        let scale: CGFloat = 4
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.withTintColor(.black).draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cg = rendered.cgImage else { return .zero }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w where pixels[y * w + x] > 76 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return .zero }
        return CGSize(width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}
