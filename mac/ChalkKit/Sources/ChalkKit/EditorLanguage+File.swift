import Foundation

public extension EditorLanguage {
    /// `.tex` is LaTeX; everything else (including `.qmd`) is Markdown.
    init(fileExtension ext: String) {
        self = ext.lowercased() == "tex" ? .tex : .md
    }

    /// The extension a new file in this language gets (no leading dot).
    var fileExtension: String {
        switch self {
        case .tex: return "tex"
        case .md: return "md"
        }
    }
}
