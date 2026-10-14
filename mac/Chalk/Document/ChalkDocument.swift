import UIKit
import ChalkKit

/// A text file as a `UIDocument`, for coordinated, crash-safe reads and writes. The in-memory text is
/// the source of truth while open; `DocumentController` decides when to write it.
final class ChalkDocument: UIDocument {
    /// The document's text. Set before calling `save` to flush an edit.
    var text: String = ""

    /// Editor language inferred from the file extension.
    var language: EditorLanguage {
        EditorLanguage(fileExtension: fileURL.pathExtension)
    }

    enum LoadError: Error {
        /// Not valid UTF-8. Refuse rather than lossy-decode, or the next save writes U+FFFD back.
        case notUTF8
        /// A directory or package (UIDocument hands back a `FileWrapper`). Opening it as a blank
        /// document would let a save replace the folder with a flat file.
        case notAFile
    }

    override func contents(forType typeName: String) throws -> Any {
        Data(text.utf8)
    }

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let data = contents as? Data else {
            throw LoadError.notAFile
        }
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw LoadError.notUTF8
        }
        text = decoded
    }
}
