import XCTest
import ChalkKit
@testable import Chalk

/// `ChalkDocument.decode` and the read path are the last gate before a file's
/// bytes become the in-memory buffer, and the buffer is what a save writes back.
/// So anything they accept silently, a later Cmd+S will happily write over the
/// original. That makes "refuse to open" the only safe response to a payload we
/// do not understand: a directory named `analysis.qmd`, or Latin-1 bytes.
final class ChalkDocumentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-doc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func open(_ doc: ChalkDocument) -> Bool {
        let done = expectation(description: "open")
        var result = false
        doc.open { ok in
            result = ok
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return result
    }

    /// Regression on the behaviour that already existed: refusing Latin-1
    /// rather than lossy-decoding it, because U+FFFD replacement would be
    /// written back on the next save.
    func testDecodeRefusesNonUTF8Bytes() {
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9]) // "café" in Latin-1
        XCTAssertThrowsError(try ChalkDocument.decode(latin1)) { error in
            XCTAssertEqual(error as? ChalkDocument.LoadError, .notUTF8)
        }
    }

    func testDecodeAcceptsUTF8Data() throws {
        XCTAssertEqual(try ChalkDocument.decode(Data("# Notes\n$x^2$".utf8)), "# Notes\n$x^2$")
    }

    func testOpeningADirectoryFailsAndLeavesTheBufferEmpty() throws {
        let folder = root.appendingPathComponent("notes.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let doc = ChalkDocument(fileURL: folder)

        XCTAssertFalse(open(doc))
        XCTAssertEqual(doc.text, "", "a refused load must leave nothing a save could write")
    }

    func testOpeningNonUTF8FailsAndLeavesTheBufferEmpty() throws {
        let file = root.appendingPathComponent("latin1.md")
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: file)
        let doc = ChalkDocument(fileURL: file)

        XCTAssertFalse(open(doc))
        XCTAssertEqual(doc.text, "")
    }

    func testOpenReadsTheFileAndSaveWritesItBack() throws {
        let file = root.appendingPathComponent("a.md")
        try Data("one\n".utf8).write(to: file)
        let doc = ChalkDocument(fileURL: file)

        XCTAssertTrue(open(doc))
        XCTAssertEqual(doc.text, "one\n")

        doc.text = "two\n"
        let saved = expectation(description: "save")
        var ok = false
        doc.save { result in
            ok = result
            saved.fulfill()
        }
        wait(for: [saved], timeout: 5)
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "two\n")
        doc.close()
    }

    func testSaveIntoAReadOnlyDirectoryReportsFailure() throws {
        let file = root.appendingPathComponent("locked.md")
        try Data("base\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        addTeardownBlock { [root] in
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root!.path)
        }
        let doc = ChalkDocument(fileURL: file)
        doc.text = "new\n"

        let saved = expectation(description: "save")
        var ok = true
        doc.save { result in
            ok = result
            saved.fulfill()
        }
        wait(for: [saved], timeout: 5)
        XCTAssertFalse(ok)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "base\n")
    }
}
