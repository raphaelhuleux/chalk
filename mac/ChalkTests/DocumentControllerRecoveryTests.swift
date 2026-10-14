import XCTest
import ChalkKit
@testable import Chalk

/// Crash recovery restore paths: a recovered snapshot re-enters the session as
/// the tab's unsaved buffer — a draft seeds with the recovered text and shows
/// dirty; a file-backed tab opens the file, then layers the recovered text on
/// top as a pending edit (dirty), unless it matches the disk content exactly
/// (stale snapshot from a completed save — stays clean).
final class DocumentControllerRecoveryTests: XCTestCase {
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

    func testOpenDraftWithRecoveredTextSeedsDirty() {
        controller.openDraft(recoveredText: "# Recovered draft\n")
        XCTAssertEqual(surface.displayedText, "# Recovered draft\n")
        XCTAssertTrue(controller.isDirty, "a recovered draft has unsaved content")
    }

    func testPlainOpenDraftStaysClean() {
        controller.openDraft()
        XCTAssertEqual(surface.displayedText, "")
        XCTAssertFalse(controller.isDirty)
    }

    func testOpenWithRecoveredTextLayersDirtyEdit() throws {
        let url = try writeTempFile(name: "notes.md", contents: "on disk\n")
        openAndWait(url, recoveredText: "recovered, newer than disk\n")

        XCTAssertEqual(surface.displayedText, "recovered, newer than disk\n",
                       "the editor shows the recovered text, not the disk text")
        XCTAssertTrue(controller.isDirty, "recovered text is an unsaved edit")
        XCTAssertEqual(controller.currentText, "recovered, newer than disk\n")
    }

    func testOpenWithRecoveredTextMatchingDiskStaysClean() throws {
        let url = try writeTempFile(name: "notes.md", contents: "same\n")
        openAndWait(url, recoveredText: "same\n")

        XCTAssertEqual(surface.displayedText, "same\n")
        XCTAssertFalse(controller.isDirty,
                       "a snapshot identical to disk is stale — no phantom dirty state")
    }

    // MARK: - layerRecoveredText (C-1: drain meets an already-open tab)

    func testLayerRecoveredTextOnLoadedDocumentGoesDirty() throws {
        let url = try writeTempFile(name: "loaded.md", contents: "disk\n")
        openAndWait(url, recoveredText: nil)

        controller.layerRecoveredText("recovered\n")

        XCTAssertTrue(controller.isDirty, "layered recovery is an unsaved edit")
        XCTAssertEqual(surface.displayedText, "recovered\n")
        XCTAssertEqual(controller.currentText, "recovered\n")
    }

    func testLayerRecoveredTextWhileOpenInFlightDefersUntilLoad() throws {
        let url = try writeTempFile(name: "inflight.md", contents: "disk\n")
        let spy = DirtySpy()
        controller.delegate = spy
        let dirty = expectation(description: "deferred layer applied on load")
        spy.onDirtyChange = { isDirty in if isDirty { dirty.fulfill() } }

        controller.open(url: url)
        // The async read hasn't completed: the layer must park, then apply in
        // the open's success completion — not vanish.
        controller.layerRecoveredText("recovered while opening\n")
        wait(for: [dirty], timeout: 5)

        XCTAssertEqual(surface.displayedText, "recovered while opening\n")
        XCTAssertEqual(controller.currentText, "recovered while opening\n")
    }

    func testLayerRecoveredTextMatchingDiskStaysClean() throws {
        let url = try writeTempFile(name: "stale.md", contents: "same\n")
        openAndWait(url, recoveredText: nil)

        controller.layerRecoveredText("same\n")

        XCTAssertFalse(controller.isDirty,
                       "a snapshot identical to the buffer is stale — no phantom dirty state")
        XCTAssertEqual(surface.displayedText, "same\n")
    }

    // MARK: - Retry after a failed open (C-2)

    /// The failed open clears `document`, and the alert's Retry then reopens
    /// the same URL. The parked crash text must survive that retry.
    func testRetryAfterFailedOpenAppliesParkedRecovery() throws {
        let url = try writeUnreadableFile(name: "locked.md", contents: "on disk\n")
        let spy = OpenOutcomeSpy()
        controller.delegate = spy
        let failed = expectation(description: "open fails")
        spy.onFailToOpen = { _ in failed.fulfill() }

        controller.open(url: url, recoveredText: "crash edits\n")
        wait(for: [failed], timeout: 5)
        XCTAssertTrue(controller.hasUnappliedRecovery)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let dirty = expectation(description: "retry loads dirty")
        spy.onDirtyChange = { isDirty in if isDirty { dirty.fulfill() } }
        controller.reopen(url: url)
        wait(for: [dirty], timeout: 5)

        XCTAssertEqual(controller.currentText, "crash edits\n")
        XCTAssertFalse(controller.hasUnappliedRecovery)
    }

    /// Browsing to a different file after the failure is not a retry: the
    /// parked text belongs to the file that failed.
    func testReopenOfAnotherFileAfterFailedOpenDropsParkedRecovery() throws {
        let url = try writeUnreadableFile(name: "locked.md", contents: "on disk\n")
        let other = try writeTempFile(name: "other.md", contents: "other\n")
        let spy = OpenOutcomeSpy()
        controller.delegate = spy
        let failed = expectation(description: "open fails")
        spy.onFailToOpen = { _ in failed.fulfill() }
        controller.open(url: url, recoveredText: "crash edits\n")
        wait(for: [failed], timeout: 5)

        let loaded = expectation(description: "other file loads")
        spy.onDirtyChange = { _ in loaded.fulfill() }
        controller.reopen(url: other)
        wait(for: [loaded], timeout: 5)

        XCTAssertEqual(controller.currentText, "other\n")
        XCTAssertFalse(controller.isDirty)
        XCTAssertFalse(controller.hasUnappliedRecovery)
    }

    // MARK: - Helpers

    private func writeUnreadableFile(name: String, contents: String) throws -> URL {
        let url = try writeTempFile(name: name, contents: contents)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        return url
    }

    private func writeTempFile(name: String, contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    private func openAndWait(_ url: URL, recoveredText: String?) {
        let spy = DirtySpy()
        controller.delegate = spy
        let done = expectation(description: "open \(url.lastPathComponent)")
        spy.onDirtyChange = { _ in done.fulfill() }
        controller.open(url: url, recoveredText: recoveredText)
        wait(for: [done], timeout: 5)
        controller.delegate = nil
    }
}

/// Observes both open outcomes: the dirty report a successful load sends, and
/// the failure a read error sends instead.
private final class OpenOutcomeSpy: DocumentControllerDelegate {
    var onDirtyChange: ((Bool) -> Void)?
    var onFailToOpen: ((URL) -> Void)?

    func documentController(_ controller: DocumentController, didChangeDirty isDirty: Bool) {
        onDirtyChange?(isDirty)
    }

    func documentController(_ controller: DocumentController, didFailToOpen url: URL) {
        onFailToOpen?(url)
    }

    func documentController(_ controller: DocumentController,
                            needsSaveDestination completion: @escaping (Bool) -> Void) {
        completion(false)
    }
}
