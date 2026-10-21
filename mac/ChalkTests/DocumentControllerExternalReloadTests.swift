import XCTest
import ChalkKit
@testable import Chalk

/// Covers `reloadIfChangedExternally`'s decision branches around the
/// NSFileCoordinator-based read: adopt a clean external change, merge one into
/// local edits, keep local edits on a clash, and refuse to adopt bytes that aren't valid UTF-8
/// (a lossy decode would become the new baseline and get written back).
final class DocumentControllerExternalReloadTests: XCTestCase {
    private var surface: FakeEditorSurface!
    private var controller: DocumentController!

    override func setUp() {
        super.setUp()
        surface = FakeEditorSurface()
        controller = DocumentController(surface: surface)
        surface.signalReady()
    }

    override func tearDown() {
        controller = nil
        surface = nil
        super.tearDown()
    }

    func testAdoptsExternalChangeWhenBufferClean() throws {
        let url = try writeTempFile(name: "a.md", contents: "# One\n")
        openAndWait(url)

        try overwrite(url, contents: "# One\n# Two\n")
        controller.reloadIfChangedExternally()
        waitForDisplayedText("# One\n# Two\n")

        XCTAssertFalse(controller.isDirty, "an adopted external change is a clean baseline")

        // The synced state must have advanced with the read: a second pass with
        // no further disk change is a no-op (no extra update/init traffic).
        let updates = surface.updateTexts.count
        let inits = surface.initializeLanguages.count
        controller.reloadIfChangedExternally()
        settle()
        XCTAssertEqual(surface.updateTexts.count, updates)
        XCTAssertEqual(surface.initializeLanguages.count, inits)
    }

    /// M-1: an external write that lands in the same mtime quantum (coarse
    /// filesystems) but changes the byte count must still be detected — the
    /// size is the second signal beside the date.
    func testAdoptsSameDateDifferentSizeExternalChange() throws {
        let url = try writeTempFile(name: "d.md", contents: "# One\n")
        openAndWait(url)

        // Overwrite with LONGER content, then force the mtime back to exactly
        // the synced date — simulating a same-second external write.
        let originalDate = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        try "# One\n# Two, same mtime\n".data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate], ofItemAtPath: url.path)

        controller.reloadIfChangedExternally()
        waitForDisplayedText("# One\n# Two, same mtime\n")
        XCTAssertFalse(controller.isDirty)
    }

    func testKeepsLocalEditsOnConflict() throws {
        let url = try writeTempFile(name: "b.md", contents: "# Base\n")
        openAndWait(url)

        // Local unsaved edit…
        controller.editor(surface, didEdit: "# Base\nlocal edit\n")
        XCTAssertTrue(controller.isDirty)

        // …then the file changes on disk. The local copy must win.
        try overwrite(url, contents: "# External\n")
        controller.reloadIfChangedExternally()
        settle() // the read is async now; give a wrong adoption time to land

        XCTAssertTrue(controller.isDirty, "the conflicting local edit must survive")
        XCTAssertFalse(surface.updateTexts.contains("# External\n"),
                       "the external text must not be pushed over local edits")
    }

    /// An agent writes the file while the tab holds an unsaved edit elsewhere: both land, the tab stays
    /// dirty, and the save that follows is not a conflict.
    func testMergesDisjointExternalChangeIntoLocalEdits() throws {
        let url = try writeTempFile(name: "m.md", contents: "a\nb\nc\nd\ne\n")
        openAndWait(url)
        controller.editor(surface, didEdit: "A\nb\nc\nd\ne\n")

        try overwrite(url, contents: "a\nb\nc\nd\ne\nagent line\n")
        controller.reloadIfChangedExternally()
        waitForDisplayedText("A\nb\nc\nd\ne\nagent line\n")
        XCTAssertTrue(controller.isDirty, "the merged local edit is still unsaved")

        let spy = ConflictSpy()
        controller.delegate = spy
        let saved = expectation(description: "save")
        controller.save { ok in
            XCTAssertTrue(ok)
            saved.fulfill()
        }
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "A\nb\nc\nd\ne\nagent line\n")
        XCTAssertTrue(spy.conflictURLs.isEmpty, "a merged change is not a save conflict")
    }

    func testSkipsExternalChangeThatIsNotUTF8() throws {
        let url = try writeTempFile(name: "c.md", contents: "# Good\n")
        openAndWait(url)

        // Overwrite with invalid UTF-8 (a lone Latin-1 é byte).
        try Data([0x23, 0x20, 0xE9, 0x0A]).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        controller.reloadIfChangedExternally()
        settle() // the read is async now; give a wrong adoption time to land

        XCTAssertEqual(surface.displayedText, "# Good\n",
                       "invalid bytes must not be lossy-decoded into the editor")
    }

    func testOpenRefusesNonUTF8File() throws {
        let url = try writeTempFile(name: "latin1.tex", contents: "")
        try Data([0x5C, 0x74, 0xE9, 0x78]).write(to: url) // "\té x" in Latin-1 — invalid UTF-8

        controller.open(url: url)
        // The open fails (ChalkDocument.LoadError.notUTF8), so the controller
        // never loads and never seeds — the editor must not show mojibake.
        let settle = expectation(description: "async open settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        wait(for: [settle], timeout: 5)

        XCTAssertNil(surface.displayedText,
                     "a non-UTF-8 file must refuse to open rather than corrupt on next save")
    }

    // MARK: - Helpers (mirrors DocumentControllerReadyRaceTests)

    private func writeTempFile(name: String, contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    private func overwrite(_ url: URL, contents: String) throws {
        try contents.data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
    }

    private func openAndWait(_ url: URL) {
        let spy = DirtySpy()
        controller.delegate = spy
        let done = expectation(description: "open \(url.lastPathComponent)")
        spy.onDirtyChange = { _ in done.fulfill() }
        controller.open(url: url)
        wait(for: [done], timeout: 5)
    }

    /// Wait for the (async, off-main) external reload to push `expected` into
    /// the editor.
    private func waitForDisplayedText(_ expected: String) {
        guard surface.displayedText != expected else { return }
        let done = expectation(description: "displayedText becomes \(expected)")
        surface.onDisplayedTextChange = { text in
            if text == expected { done.fulfill() }
        }
        wait(for: [done], timeout: 5)
        surface.onDisplayedTextChange = nil
    }

    /// Let the utility-queue read and its main-queue hop run to completion, for
    /// tests asserting that NOTHING was adopted.
    private func settle(_ delay: TimeInterval = 0.5) {
        let done = expectation(description: "settle")
        DispatchQueue.global(qos: .utility).async {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { done.fulfill() }
        }
        wait(for: [done], timeout: 5)
    }
}

private final class ConflictSpy: DocumentControllerDelegate {
    var conflictURLs: [URL] = []
    func documentController(_ controller: DocumentController, didChangeDirty isDirty: Bool) {}
    func documentController(_ controller: DocumentController,
                            needsSaveDestination completion: @escaping (Bool) -> Void) {
        completion(false)
    }
    func documentController(_ controller: DocumentController,
                            hasSaveConflictAt url: URL, backupAt backupURL: URL?) {
        conflictURLs.append(url)
    }
}
