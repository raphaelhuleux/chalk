import XCTest
import ChalkKit
@testable import Chalk

/// save()'s data-integrity contracts from the pre-release audit:
/// - C-3: a file changed externally since our last read/write gets its disk
///   version copied aside to `<name>.conflict.<ext>` and the delegate told,
///   then the write proceeds (Keep Mine is the effective default).
/// - H-5: a failed write surfaces through `didFailSaveTo` and keeps the
///   buffer dirty for retry.
/// - M-2: a rebind landing mid-save reports failure (the write went to the
///   old path) so the buffer stays dirty for the next save.
/// - D11: `documentControllerDidSave` fires only in the success completion,
///   and only when something actually flushed.
final class DocumentControllerSaveConflictTests: XCTestCase {
    private var surface: FakeEditorSurface!
    private var controller: DocumentController!
    private var spy: SaveSpy!

    override func setUp() {
        super.setUp()
        surface = FakeEditorSurface()
        controller = DocumentController(surface: surface)
        spy = SaveSpy()
        controller.delegate = spy
        surface.signalReady()
    }

    override func tearDown() {
        controller = nil
        surface = nil
        spy = nil
        super.tearDown()
    }

    func testConflictGateCopiesDiskAsideNotifiesAndStillWrites() throws {
        let url = try writeTempFile(name: "doc.md", contents: "base\n")
        openAndWait(url)

        controller.editor(surface, didEdit: "mine\n")
        // External write after our last read: newer mtime, different content.
        try "theirs\n".data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)

        let saved = expectation(description: "save completes")
        var savedOK: Bool?
        controller.save { ok in
            savedOK = ok
            saved.fulfill()
        }
        wait(for: [saved], timeout: 5)

        XCTAssertEqual(savedOK, true, "the write proceeds — the copy-aside is the floor")
        XCTAssertEqual(spy.conflictURLs, [url], "the delegate must hear about the conflict")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "mine\n",
                       "our version wins the original path")
        let conflictURL = url.deletingPathExtension()
            .appendingPathExtension("conflict").appendingPathExtension("md")
        XCTAssertEqual(try String(contentsOf: conflictURL, encoding: .utf8), "theirs\n",
                       "the losing disk version survives as the .conflict sibling")
        XCTAssertEqual(spy.conflictBackups, [conflictURL],
                       "the delegate hears WHERE the copy actually went (C-3a)")
        XCTAssertFalse(controller.isDirty)
    }

    /// A second conflict on the same file must not replace the first copy:
    /// each one is the only record of a version that lost.
    func testSecondConflictKeepsTheFirstCopy() throws {
        let url = try writeTempFile(name: "twice.md", contents: "base\n")
        openAndWait(url)

        for (mine, theirs) in [("mine 1\n", "theirs 1\n"), ("mine 2\n", "theirs 2\n")] {
            controller.editor(surface, didEdit: mine)
            try theirs.data(using: .utf8)!.write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(10 + Double(spy.conflictURLs.count) * 10)],
                ofItemAtPath: url.path)
            let saved = expectation(description: "save completes")
            controller.save { _ in saved.fulfill() }
            wait(for: [saved], timeout: 5)
        }

        let dir = url.deletingLastPathComponent()
        let first = dir.appendingPathComponent("twice.conflict.md")
        let second = dir.appendingPathComponent("twice 2.conflict.md")
        XCTAssertEqual(spy.conflictBackups, [first, second])
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "theirs 1\n")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "theirs 2\n")
    }

    /// C-3 gate hardening: coarse-mtime filesystems (FAT/SMB) can hand an
    /// external rewrite the same second-quantized date. The gate must use the
    /// same (date, size) predicate as reloadIfChangedExternally, not `>`.
    func testConflictGateFiresOnSameDateDifferentSize() throws {
        let url = try writeTempFile(name: "coarse.md", contents: "base\n")
        openAndWait(url)
        controller.editor(surface, didEdit: "mine\n")

        // External write with a DIFFERENT size but the ORIGINAL mtime.
        let originalDate = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as! Date
        try "theirs, longer\n".data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate], ofItemAtPath: url.path)

        let saved = expectation(description: "save completes")
        controller.save { _ in saved.fulfill() }
        wait(for: [saved], timeout: 5)

        XCTAssertEqual(spy.conflictURLs, [url],
                       "a same-second external rewrite must still trip the gate")
        let conflictURL = url.deletingPathExtension()
            .appendingPathExtension("conflict").appendingPathExtension("md")
        XCTAssertEqual(try String(contentsOf: conflictURL, encoding: .utf8), "theirs, longer\n")
    }

    /// C-3a: when the sibling copy is denied (per-file sandbox scope), the
    /// disk version must land in the app's recovery folder instead of being
    /// silently lost — and the delegate must hear the real destination.
    func testConflictCopyFallsBackToRecoveryFolderWhenSiblingDenied() throws {
        let url = try writeTempFile(name: "scoped.md", contents: "base\n")
        openAndWait(url)
        controller.editor(surface, didEdit: "mine\n")
        try "theirs\n".data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)

        // Read+execute only: the sibling copy AND the save both fail, but the
        // copy-aside must still succeed into Application Support.
        let dir = url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        }
        let countBefore = privacyConflictCount()

        let saved = expectation(description: "save completes")
        controller.save { _ in saved.fulfill() }
        wait(for: [saved], timeout: 10)

        XCTAssertEqual(spy.conflictURLs, [url])
        let backup = try XCTUnwrap(spy.conflictBackups.first ?? nil,
                                   "a fallback copy must exist when the sibling is denied")
        addTeardownBlock { try? FileManager.default.removeItem(at: backup) }
        XCTAssertEqual(backup.deletingLastPathComponent().standardizedFileURL,
                       RecoveryStore.conflictCopiesDirectory.standardizedFileURL,
                       "the fallback is the one folder the Privacy screen reports on")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "theirs\n")
        XCTAssertEqual(privacyConflictCount(), countBefore + 1,
                       "the Privacy screen counts the copy it tells the user about")
    }

    /// C-3b: resign-active and didEnterBackground both run saveAll; the
    /// trailing save must coalesce onto the in-flight write instead of
    /// mistaking our own fresh mtime for an external conflict.
    func testOverlappingSavesRaiseNoSelfConflict() throws {
        let url = try writeTempFile(name: "overlap.md", contents: "base\n")
        openAndWait(url)
        controller.editor(surface, didEdit: "edited\n")

        let first = expectation(description: "first save")
        let second = expectation(description: "second save")
        var results: [Bool] = []
        controller.save { ok in results.append(ok); first.fulfill() }
        controller.save { ok in results.append(ok); second.fulfill() }
        wait(for: [first, second], timeout: 5)

        XCTAssertEqual(results, [true, true])
        XCTAssertTrue(spy.conflictURLs.isEmpty,
                      "our own in-flight write is not an external change")
        XCTAssertEqual(spy.didSaveCount, 1, "one flush, not two")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "edited\n")
        let conflictURL = url.deletingPathExtension()
            .appendingPathExtension("conflict").appendingPathExtension("md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: conflictURL.path),
                       "no junk .conflict file from the race")
    }

    func testCleanSaveOverOwnWriteRaisesNoConflict() throws {
        let url = try writeTempFile(name: "noconf.md", contents: "base\n")
        openAndWait(url)

        controller.editor(surface, didEdit: "v2\n")
        let saved = expectation(description: "first save")
        controller.save { _ in saved.fulfill() }
        wait(for: [saved], timeout: 5)

        controller.editor(surface, didEdit: "v3\n")
        let saved2 = expectation(description: "second save")
        controller.save { _ in saved2.fulfill() }
        wait(for: [saved2], timeout: 5)

        XCTAssertTrue(spy.conflictURLs.isEmpty,
                      "saving over our own previous write is not a conflict")
        let conflictURL = url.deletingPathExtension()
            .appendingPathExtension("conflict").appendingPathExtension("md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: conflictURL.path))
    }

    func testSaveFailureNotifiesDelegateAndKeepsBufferDirty() throws {
        let url = try writeTempFile(name: "locked.md", contents: "base\n")
        openAndWait(url)
        controller.editor(surface, didEdit: "unsaved\n")

        // Make the parent directory read-only: the atomic write lands a sidecar
        // then swaps it into the directory, which now fails.
        let dir = url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        }

        let saved = expectation(description: "save fails")
        var savedOK: Bool?
        controller.save { ok in
            savedOK = ok
            saved.fulfill()
        }
        wait(for: [saved], timeout: 10)

        XCTAssertEqual(savedOK, false)
        XCTAssertEqual(spy.failedSaveURLs, [url], "the failure must reach the delegate")
        XCTAssertTrue(controller.isDirty, "the buffer is kept for retry")
        XCTAssertEqual(controller.currentText, "unsaved\n")
    }

    func testRebindMidSaveReportsFailureAndKeepsBufferDirty() throws {
        let a = try writeTempFile(name: "a.md", contents: "base\n")
        let b = try writeTempFile(name: "b.md", contents: "other\n")
        openAndWait(a)
        controller.editor(surface, didEdit: "edited\n")

        let saved = expectation(description: "save completes after rebind")
        var savedOK: Bool?
        controller.save { ok in
            savedOK = ok
            saved.fulfill()
        }
        // The coordinated write is async; the rename lands before its completion.
        controller.rebind(to: b)
        wait(for: [saved], timeout: 5)

        XCTAssertEqual(savedOK, false,
                       "a flush that landed at the old path must not be confirmed")
        XCTAssertTrue(controller.isDirty,
                      "the buffer stays dirty so the next save writes to the new path")
    }

    func testDidSaveFiresOnlyOnConfirmedFlushOfRealChanges() throws {
        let url = try writeTempFile(name: "preview.md", contents: "base\n")
        openAndWait(url)

        // Nothing to flush: a saveAll-style pass must NOT commit the tab.
        let noop = expectation(description: "no-op save")
        controller.save { _ in noop.fulfill() }
        wait(for: [noop], timeout: 5)
        XCTAssertEqual(spy.didSaveCount, 0,
                       "a save with nothing to flush must not fire didSave (D11)")

        controller.editor(surface, didEdit: "real change\n")
        let real = expectation(description: "real save")
        controller.save { ok in
            XCTAssertTrue(ok)
            real.fulfill()
        }
        wait(for: [real], timeout: 5)
        XCTAssertEqual(spy.didSaveCount, 1,
                       "a confirmed write of real changes fires didSave exactly once")
    }

    // MARK: - iCloud conflict versions (C-4)

    /// Every loser is copied, and only the ones whose copy landed leave the
    /// version store. The one that failed stays in conflict: discarding it
    /// would delete the only copy of that version.
    func testSettleCopiesEveryLoserAndDiscardsOnlyTheCopiedOnes() {
        let now = Date()
        let old = FakeConflictVersion(name: "old", modified: now.addingTimeInterval(-60))
        let failing = FakeConflictVersion(name: "failing", modified: now.addingTimeInterval(-30))
        let newest = FakeConflictVersion(name: "newest", modified: now)
        var copied: [String] = []

        let reported = DocumentController.settleConflictVersions([old, failing, newest]) { source in
            copied.append(source.lastPathComponent)
            return source == failing.url ? nil : URL(fileURLWithPath: "/copies/\(source.lastPathComponent)")
        }

        XCTAssertEqual(copied, ["newest", "failing", "old"], "every loser is copied, newest first")
        XCTAssertTrue(newest.discarded)
        XCTAssertTrue(old.discarded)
        XCTAssertFalse(failing.discarded, "a version whose copy failed stays in conflict")
        XCTAssertEqual(reported, URL(fileURLWithPath: "/copies/newest"))
    }

    func testSettleWithNoCopyDiscardsNothingAndReportsNothing() {
        let a = FakeConflictVersion(name: "a", modified: Date())
        let b = FakeConflictVersion(name: "b", modified: nil)

        let reported = DocumentController.settleConflictVersions([a, b]) { _ in nil }

        XCTAssertNil(reported)
        XCTAssertFalse(a.discarded)
        XCTAssertFalse(b.discarded)
    }

    /// A rename and a draft's first save both give the controller a new
    /// document; the iCloud-conflict watch has to follow it there.
    func testConflictWatchFollowsRebindAndDraftBinding() throws {
        let url = try writeTempFile(name: "watched.md", contents: "base\n")
        openAndWait(url)
        XCTAssertTrue(controller.watchesConflictsOfCurrentDocumentForTesting)

        let renamed = url.deletingLastPathComponent().appendingPathComponent("renamed.md")
        try FileManager.default.moveItem(at: url, to: renamed)
        controller.rebind(to: renamed)
        XCTAssertTrue(controller.watchesConflictsOfCurrentDocumentForTesting,
                      "a rename keeps conflict detection on")

        let draft = DocumentController(surface: FakeEditorSurface())
        draft.openDraft()
        let saved = try writeTempFile(name: "draft.md", contents: "draft\n")
        draft.bindDraft(to: saved, writtenText: "draft\n")
        XCTAssertTrue(draft.watchesConflictsOfCurrentDocumentForTesting,
                      "a saved draft gets conflict detection")
    }

    // MARK: - Helpers

    private func writeTempFile(name: String, contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    /// The conflict copies kept in Chalk's folder, which is what the Privacy screen counts.
    private func privacyConflictCount() -> Int {
        let dir = RecoveryStore.conflictCopiesDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.count
    }

    private func openAndWait(_ url: URL) {
        let done = expectation(description: "open \(url.lastPathComponent)")
        spy.onDirtyChange = { _ in done.fulfill() }
        controller.open(url: url)
        wait(for: [done], timeout: 5)
        spy.onDirtyChange = nil
    }
}

/// Records every save-related delegate callback.
private final class SaveSpy: DocumentControllerDelegate {
    var onDirtyChange: ((Bool) -> Void)?
    private(set) var didSaveCount = 0
    private(set) var conflictURLs: [URL] = []
    private(set) var conflictBackups: [URL?] = []
    private(set) var failedSaveURLs: [URL] = []

    func documentController(_ controller: DocumentController, didChangeDirty isDirty: Bool) {
        onDirtyChange?(isDirty)
    }

    func documentController(_ controller: DocumentController,
                            needsSaveDestination completion: @escaping (Bool) -> Void) {
        completion(false)
    }

    func documentControllerDidSave(_ controller: DocumentController) {
        didSaveCount += 1
    }

    func documentController(_ controller: DocumentController,
                            hasSaveConflictAt url: URL, backupAt backupURL: URL?) {
        conflictURLs.append(url)
        conflictBackups.append(backupURL)
    }

    func documentController(_ controller: DocumentController, didFailSaveTo url: URL) {
        failedSaveURLs.append(url)
    }
}

private final class FakeConflictVersion: ConflictVersion {
    let url: URL
    let modificationDate: Date?
    private(set) var discarded = false

    init(name: String, modified: Date?) {
        url = URL(fileURLWithPath: "/versions/\(name)")
        modificationDate = modified
    }

    func discard() throws { discarded = true }
}
