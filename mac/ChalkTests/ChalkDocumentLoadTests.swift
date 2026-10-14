import XCTest
@testable import Chalk

/// `load(fromContents:)` is the last gate before a file's bytes become the
/// in-memory buffer, and the buffer is what `contents(forType:)` writes back.
/// So anything this method accepts silently, a later Cmd+S will happily write
/// over the original. That makes "refuse to open" the only safe response to a
/// payload we do not understand.
///
/// UIDocument hands back a `FileWrapper` rather than `Data` when the target is
/// a directory or a package. Reported as success with an empty buffer, a
/// folder named `analysis.qmd` opens as a blank document, and one keystroke
/// plus Cmd+S replaces the folder with a flat file.
final class ChalkDocumentLoadTests: XCTestCase {
    private func document() -> ChalkDocument {
        ChalkDocument(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-load-\(UUID().uuidString).md"))
    }

    func testLoadThrowsForADirectorysFileWrapper() throws {
        let doc = document()
        let wrapper = FileWrapper(directoryWithFileWrappers: [:])

        XCTAssertThrowsError(try doc.load(fromContents: wrapper, ofType: nil))
    }

    /// The buffer must stay empty rather than pick up a partial value, because
    /// a non-empty buffer is what a later save would write.
    func testLoadLeavesTheBufferEmptyWhenItRefuses() throws {
        let doc = document()

        try? doc.load(fromContents: FileWrapper(directoryWithFileWrappers: [:]),
                      ofType: nil)

        XCTAssertEqual(doc.text, "")
    }

    func testLoadThrowsForAPayloadThatIsNeitherDataNorFileWrapper() {
        let doc = document()

        XCTAssertThrowsError(try doc.load(fromContents: NSNull(), ofType: nil))
    }

    /// Regression on the behaviour that already existed: refusing Latin-1
    /// rather than lossy-decoding it, because U+FFFD replacement would be
    /// written back on the next save.
    func testLoadStillRefusesNonUTF8Bytes() {
        let doc = document()
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9]) // "café" in Latin-1

        XCTAssertThrowsError(try doc.load(fromContents: latin1, ofType: nil)) { error in
            XCTAssertEqual(error as? ChalkDocument.LoadError, .notUTF8)
        }
    }

    func testLoadAcceptsUTF8Data() throws {
        let doc = document()

        try doc.load(fromContents: Data("# Notes\n$x^2$".utf8), ofType: nil)

        XCTAssertEqual(doc.text, "# Notes\n$x^2$")
    }
}
