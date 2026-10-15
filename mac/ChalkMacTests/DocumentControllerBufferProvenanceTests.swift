import XCTest
import ChalkKit
@testable import ChalkMac

/// `save()` writes `buffer` to `document`. Nothing at that write checks that
/// the two belong together, so any path that leaves them mismatched writes one
/// file's text over another's path. Today the only such path is a failed
/// reopen, and it is unreachable because typing commits a tab and committed
/// tabs are never browse-reused. That is an invariant living two files away
/// from the write it protects, and it would break silently.
///
/// These tests pin the guarantee at the write itself.
final class DocumentControllerBufferProvenanceTests: XCTestCase {
    private var surface: FakeEditorSurface!
    private var controller: DocumentController!
    private var root: URL!
    private var fileA: URL!
    private var failingB: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        surface = FakeEditorSurface()
        controller = DocumentController(surface: surface)
        surface.signalReady()

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileA = root.appendingPathComponent("a.md")
        try Data("ORIGINAL A".utf8).write(to: fileA)
        failingB = root.appendingPathComponent("b.md")
        try FileManager.default.createDirectory(at: failingB, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: failingB.appendingPathComponent("keep.md"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        controller = nil
        surface = nil
        try super.tearDownWithError()
    }

    private func settle(_ seconds: TimeInterval = 1.0) {
        let done = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 4)
    }

    /// The probe that found this: unsaved edits, then a browse to a file that
    /// fails to open, then a save.
    func testUnsavedEditsAreNeverWrittenToADifferentFilesPath() throws {
        controller.open(url: fileA)
        settle()
        controller.editor(surface, didEdit: "ORIGINAL A, with unsaved edits")
        XCTAssertTrue(controller.isDirty)

        let spy = FailedSaveSpy()
        controller.delegate = spy
        controller.reopen(url: failingB)
        settle(1.5)
        controller.save()
        settle(1.5)

        XCTAssertEqual(spy.failedSaveURLs, [failingB], "the refusal is reported")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: failingB.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "b.md was replaced by a's unsaved edits")
        XCTAssertEqual(
            try String(contentsOf: failingB.appendingPathComponent("keep.md"), encoding: .utf8),
            "keep me")
    }

    /// A CLEAN tab whose browse failed has nothing to write. The automatic
    /// flush on resign-active (Cmd-Tab) saves every tab, and it must not raise
    /// "Couldn't Save" for this one.
    func testCleanTabAfterFailedReopenSavesAsANoOp() throws {
        let spy = FailedSaveSpy()
        controller.delegate = spy
        controller.open(url: fileA)
        settle()
        XCTAssertFalse(controller.isDirty)

        controller.reopen(url: failingB)
        settle(1.5)
        var result: Bool?
        controller.save { result = $0 }

        XCTAssertEqual(result, true, "nothing to write is a successful no-op")
        XCTAssertTrue(spy.failedSaveURLs.isEmpty, "no save-failure alert for a clean tab")
    }

    /// The ordinary case must keep working: edits belonging to the open file
    /// still save to it.
    func testEditsStillSaveToTheFileTheyCameFrom() throws {
        controller.open(url: fileA)
        settle()
        controller.editor(surface, didEdit: "ORIGINAL A, edited")
        controller.save()
        settle(1.5)

        XCTAssertEqual(try String(contentsOf: fileA, encoding: .utf8),
                       "ORIGINAL A, edited")
    }

    /// A rename keeps the buffer and moves the document to a new URL on
    /// purpose, so the guard must follow the rename rather than block it.
    func testARenameStillSavesTheCarriedBufferToTheNewPath() throws {
        controller.open(url: fileA)
        settle()
        controller.editor(surface, didEdit: "ORIGINAL A, edited")

        let renamed = root.appendingPathComponent("renamed.md")
        try FileManager.default.moveItem(at: fileA, to: renamed)
        controller.rebind(to: renamed)
        controller.save()
        settle(1.5)

        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8),
                       "ORIGINAL A, edited")
    }
}

private final class FailedSaveSpy: DocumentControllerDelegate {
    private(set) var failedSaveURLs: [URL] = []

    func documentController(_ controller: DocumentController, didChangeDirty isDirty: Bool) {}

    func documentController(_ controller: DocumentController,
                            needsSaveDestination completion: @escaping (Bool) -> Void) {
        completion(false)
    }

    func documentController(_ controller: DocumentController, didFailSaveTo url: URL) {
        failedSaveURLs.append(url)
    }
}
