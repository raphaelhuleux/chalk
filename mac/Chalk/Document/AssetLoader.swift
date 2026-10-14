import Foundation
import PDFKit
import UIKit
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

    private static func rasterizedPDF(url: URL) -> String? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(2, CGFloat(maxPDFPixelDimension) / max(bounds.width, bounds.height))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .cropBox)
        guard let bytes = image.pngData() else { return nil }
        return AssetResolution.dataURL(mime: "image/png", bytes: bytes)
    }
}
