import Foundation
import ChalkKit

extension TikzRenderService {
    /// One per app, so every window and tab shares the cache and the cap on
    /// concurrent pdflatex runs. A sandboxed build can't launch TeX Live, so
    /// it answers nil and pictures stay source-only.
    static let shared = TikzRenderService(
        locator: { CompileController.isSandboxed ? nil : CompileController.makeLocator() },
        cacheDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.huleux.chalk", isDirectory: true)
            .appendingPathComponent("tikz", isDirectory: true)
    )
}
