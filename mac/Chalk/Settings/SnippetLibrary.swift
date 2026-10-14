import Foundation
import ChalkKit

/// Single source for the hsnips sent to editors: bundled defaults plus the user's Settings edits.
/// Cached because every tab init requests it; `invalidate()` when snippets change.
final class SnippetLibrary {
    static let shared = SnippetLibrary()

    let store = UserSnippetStore()
    private var cached: String?
    private var hasComposed = false

    /// The composed hsnips content, or nil when the bundled file is missing
    /// (the editor then just runs without snippets).
    func composedContent() -> String? {
        if hasComposed { return cached }
        cached = Self.bundledHsnips().map {
            SnippetComposer.compose(
                base: $0,
                user: store.snippets(),
                disabledBuiltins: store.disabledBuiltinKeys()
            )
        }
        hasComposed = true
        return cached
    }

    func invalidate() {
        cached = nil
        hasComposed = false
    }

    /// Built-ins for the Settings list, scanned once from the bundled file.
    lazy var builtins: [BuiltinSnippet] = {
        guard let base = Self.bundledHsnips() else { return [] }
        return HSnipsCatalog.scan(base)
    }()

    /// The bundled `latex.hsnips`, shipped beside the editor under `editor/`.
    static func bundledHsnips() -> String? {
        guard let dir = Bundle.main.url(forResource: "editor", withExtension: nil) else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent("latex.hsnips"), encoding: .utf8)
    }
}
