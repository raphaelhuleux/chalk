import AppKit
import Foundation
import PDFKit
import ChalkKit

/// Reads a resolved asset and packages it as a data URL for the webview's `<img>`; PDFs are
/// rasterized (page 1). The pure path logic lives in ChalkKit's `AssetResolution` so `swift test`
/// covers it without PDFKit.
enum AssetLoader {
    /// Long-edge pixel bound for rasterized PDFs, keeping the data URL small since the reply travels
    /// through `evaluateJavaScript`.
    static let maxPDFPixelDimension = 3600

    static func loadDataURL(url: URL, kind: AssetKind) -> String? {
        // Metadata gate before reading: an over-cap file never touches memory.
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey])).flatMap(\.fileSize),
           size > AssetResolution.maxAssetBytes {
            return nil
        }
        switch kind {
        case .png, .jpeg:
            guard let mime = kind.mimeType,
                  let bytes = try? Data(contentsOf: url) else { return nil }
            return AssetResolution.dataURL(mime: mime, bytes: bytes)
        case .pdf:
            return rasterizedPDF(url: url)
        }
    }

    /// Drawn into an explicit bitmap, not through `PDFPage.thumbnail`: that one sizes its backing
    /// store by the main screen's scale, so the pixel bound would depend on the display.
    private static func rasterizedPDF(url: URL) -> String? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(2, CGFloat(maxPDFPixelDimension) / max(bounds.width, bounds.height))
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let bytes = rep.representation(using: .png, properties: [:]) else { return nil }
        return AssetResolution.dataURL(mime: "image/png", bytes: bytes)
    }
}
