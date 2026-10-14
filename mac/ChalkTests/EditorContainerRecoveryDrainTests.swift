import XCTest
import ChalkKit
@testable import Chalk

/// The crash-recovery drain's data-integrity contracts (C-1 / M-4): a snapshot
/// whose file session restore already reopened clean is LAYERED onto that tab
/// (never dropped), every branch re-keys the snapshot under its new tab id
/// BEFORE clearing the old record, and a `matchingOwnTabsOnly` pass leaves
/// unclaimed records for the once-per-process leftover drain.
final class EditorContainerRecoveryDrainTests: XCTestCase {
    private var editor: EditorContainerViewController!
    private var store: RecoveryStore!
    private var storeDir: URL!

    override func setUp() {
        super.setUp()
        editor = EditorContainerViewController()
        editor.loadViewIfNeeded()
        storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-drain-tests-\(UUID().uuidString)", isDirectory: true)
        store = RecoveryStore(directory: storeDir)
        editor.setRecoveryStoreForTesting(store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeDir)
        editor = nil
        store = nil
        super.tearDown()
    }

    /// The C-1 crash scenario: session restore reopened the file clean, then
    /// the drain runs. The recovered text must layer onto the existing tab as
    /// unsaved edits and the snapshot must survive, re-keyed — not be deleted.
    func testDrainLayersRecoveredTextOntoExistingTabAndReKeysSnapshot() throws {
        let url = try writeTempFile(name: "notes.md", contents: "on disk\n")
        editor.open(url: url) // the session-restore-style clean open
        try store.snapshot(id: "crashed-tab-id", text: "recovered, newer than disk\n", fileURL: url, launchID: "previous-launch")

        editor.restoreRecoveredBuffers()

        XCTAssertEqual(editor.tabItemsForTesting.count, 1,
                       "the recovered text layers onto the existing tab — no duplicate")
        // The clean open may still be in flight when the drain layers
        // (deferred path); the tab must come out dirty either way.
        waitUntil("restored tab reports dirty") {
            self.editor.tabItemsForTesting.first?.isDirty == true
        }

        let tabID = try XCTUnwrap(editor.tabItemsForTesting.first?.id)
        let pending = store.pending()
        XCTAssertEqual(pending.map(\.id), [tabID.uuidString],
                       "snapshot re-keyed under the surviving tab id; crashed id cleared")
        XCTAssertEqual(pending.first?.text, "recovered, newer than disk\n",
                       "the recovered text is still on disk, not destroyed")
    }

    /// The draft branch (also the stand-in for "open failed": no file to open).
    /// The record must be re-keyed under the new tab BEFORE the old id is
    /// cleared, so at no point does the text exist only in memory.
    func testDrainDraftRecordReKeysUnderNewTabBeforeClearing() throws {
        try store.snapshot(id: "crashed-draft", text: "draft text\n", fileURL: nil, launchID: "previous-launch")

        editor.restoreRecoveredBuffers()

        let items = editor.tabItemsForTesting
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].isDirty, "a recovered draft opens dirty")
        let pending = store.pending()
        XCTAssertEqual(pending.map(\.id), [items[0].id.uuidString],
                       "old record cleared only after the re-key landed")
        XCTAssertEqual(pending.first?.text, "draft text\n")
    }

    /// M-4: a per-scene drain claims only records matching its own tabs; a
    /// record belonging to no tab of this window stays put for its owning
    /// window (or the deferred leftover drain, which then picks it up).
    func testOwnTabsOnlyDrainLeavesUnclaimedRecordsForLeftoverPass() throws {
        let url = try writeTempFile(name: "other-window.md", contents: "x\n")
        try store.snapshot(id: "other-window-tab", text: "their edits\n", fileURL: url, launchID: "previous-launch")

        editor.restoreRecoveredBuffers(matchingOwnTabsOnly: true)

        XCTAssertEqual(editor.tabItemsForTesting.count, 0,
                       "an own-tabs-only pass must not steal another window's record")
        XCTAssertEqual(store.pending().map(\.id), ["other-window-tab"],
                       "the record survives untouched for its owner")

        // The leftover drain then recovers it here (no other window claimed it).
        editor.restoreRecoveredBuffers(matchingOwnTabsOnly: false)
        let items = editor.tabItemsForTesting
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(store.pending().map(\.id), [items[0].id.uuidString],
                       "leftover drain re-keys before clearing, like every branch")
    }

    /// The timer/resign-active snapshot batch runs on a background queue (the
    /// encode+write of a large doc was a periodic main-thread hitch). The
    /// batch must still land — and the clean-tab clear with it.
    func testSnapshotDirtyBuffersLandsOnDiskAfterQueueDrain() throws {
        try store.snapshot(id: "crashed-draft", text: "draft text\n", fileURL: nil, launchID: "previous-launch")
        editor.restoreRecoveredBuffers() // → one dirty draft tab, re-keyed record
        let tabID = try XCTUnwrap(editor.tabItemsForTesting.first?.id).uuidString
        store.clear(id: tabID) // start the assertion from an empty store
        XCTAssertTrue(store.pending().isEmpty)

        editor.snapshotDirtyBuffers()
        editor.drainRecoveryQueueForTesting()

        XCTAssertEqual(store.pending().map(\.id), [tabID],
                       "the async batch wrote the dirty tab's snapshot")
        XCTAssertEqual(store.pending().first?.text, "draft text\n")
    }

    /// M-5: a record stamped by the RUNNING launch is a live window's timer
    /// snapshot of currently-dirty state, not crash residue. A mid-session
    /// drain (a new scene connecting via "Open in New Window") must leave it
    /// alone — layering it would resurrect seconds-old text as phantom edits.
    func testDrainSkipsRecordsStampedByTheCurrentLaunch() throws {
        let url = try writeTempFile(name: "live.md", contents: "disk\n")
        try store.snapshot(id: "live-tab", text: "live dirty text\n", fileURL: url) // default stamp = this launch

        editor.restoreRecoveredBuffers()

        XCTAssertEqual(editor.tabItemsForTesting.count, 0,
                       "a live snapshot must not be recovered mid-session")
        XCTAssertEqual(store.pending().map(\.id), ["live-tab"],
                       "and must survive untouched for its owning window")
    }

    /// C-2: a restore whose UIDocument open FAILS (unreadable file, revoked
    /// scope) must not lose the re-keyed snapshot — not to resign-active's
    /// clean-tab sweep, not to a mid-session dirty toggle — and Retry must
    /// finally surface the recovered text once the file is readable again.
    func testFailedRestoreOpenKeepsSnapshotAndRetryAppliesIt() throws {
        let url = try writeTempFile(name: "locked.md", contents: "on disk\n")
        try store.snapshot(id: "crashed-locked", text: "crash edits\n", fileURL: url, launchID: "previous-launch")
        // Unreadable: the drain's file-exists branch runs, then the open fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }

        editor.restoreRecoveredBuffers()
        let controller = try XCTUnwrap(editor.tabControllerForTesting(at: 0))
        // Wait for the failure itself: parked-and-clean is also true while the
        // open is still in flight, and a Retry that lands before the failure
        // never sees the state the alert's Retry does.
        waitUntil("the open fails") { self.editor.openFailuresForTesting == [url] }
        XCTAssertTrue(controller.hasUnappliedRecovery && !controller.isDirty,
                      "recovered text stays parked on the failed tab")
        let tabID = try XCTUnwrap(editor.tabItemsForTesting.first?.id)
        XCTAssertEqual(store.pending().map(\.id), [tabID.uuidString],
                       "the snapshot was re-keyed and must still exist")

        // Resign-active's sweep sees a clean tab; it must NOT clear the record.
        editor.snapshotDirtyBuffers()
        editor.drainRecoveryQueueForTesting()
        XCTAssertEqual(store.pending().map(\.text), ["crash edits\n"],
                       "a clean-but-unapplied tab is not a stale record")

        // Retry once the file is readable again (the failure alert's action).
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        controller.reopen(url: url)
        waitUntil("retry applies the crash edits") {
            controller.isDirty && controller.currentText == "crash edits\n"
        }
        XCTAssertFalse(controller.hasUnappliedRecovery,
                       "applied text is no longer parked; normal clears resume")
        editor.drainRecoveryQueueForTesting()
        XCTAssertEqual(store.pending().map(\.text), ["crash edits\n"],
                       "the retry's dirty report keeps the snapshot")
    }

    /// A failed-restore tab reads clean and uncommitted, which is exactly what
    /// a sidebar browse click reuses. Browsing it away would drop the parked
    /// crash edits, so it must open a new tab instead.
    func testBrowseClickDoesNotReuseTabWithParkedRecovery() throws {
        let url = try writeTempFile(name: "locked.md", contents: "on disk\n")
        let other = try writeTempFile(name: "other.md", contents: "other\n")
        try store.snapshot(id: "crashed-locked", text: "crash edits\n", fileURL: url, launchID: "previous-launch")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }

        editor.restoreRecoveredBuffers()
        let controller = try XCTUnwrap(editor.tabControllerForTesting(at: 0))
        waitUntil("the open fails") { self.editor.openFailuresForTesting == [url] }

        editor.open(url: other, reuseCurrentIfClean: true)

        XCTAssertEqual(editor.tabItemsForTesting.count, 2, "the browse opened its own tab")
        XCTAssertTrue(controller.hasUnappliedRecovery, "the crash edits are still parked")
        editor.drainRecoveryQueueForTesting()
        XCTAssertEqual(store.pending().map(\.text), ["crash edits\n"])
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

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(condition(), what)
    }
}
