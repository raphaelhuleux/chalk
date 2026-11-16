import AppKit

extension NSImage {
    /// The opaque extent of what this image draws, in points, rendered at 4x so sub-point edges
    /// count. Glyph sizes are asserted on ink, not on the image box: a symbol's box carries
    /// padding that varies with weight and size.
    var inkSizeForTesting: CGSize {
        let scale: CGFloat = 4
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return .zero }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: CGRect(x: 0, y: 0, width: w, height: h))
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
