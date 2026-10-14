import XCTest
@testable import ChalkKit

/// Chalk deliberately has no autosave: unsaved edits live only in memory until
/// Cmd+S. RecoveryStore is the crash net — periodic snapshots of dirty buffers
/// on disk, restored on the next launch after a crash/force-quit, cleared on
/// save/clean-close so a graceful session leaves nothing behind.
final class RecoveryStoreTests: XCTestCase {
    private var dir: URL!
    private var store: RecoveryStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-recovery-\(UUID().uuidString)")
        store = RecoveryStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testStartsEmpty() {
        XCTAssertTrue(store.pending().isEmpty)
    }

    func testSnapshotRoundTripsDraft() throws {
        try store.snapshot(id: "tab1", text: "# Draft\ncontent", fileURL: nil)

        let fresh = RecoveryStore(directory: dir)
        let pending = fresh.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, "tab1")
        XCTAssertEqual(pending.first?.text, "# Draft\ncontent")
        XCTAssertNil(pending.first?.fileURL)
    }

    func testSnapshotRoundTripsFileBacked() throws {
        let file = dir.appendingPathComponent("notes.md")
        try store.snapshot(id: "tab2", text: "edited", fileURL: file)

        let pending = RecoveryStore(directory: dir).pending()
        XCTAssertEqual(pending.first?.fileURL?.standardizedFileURL, file.standardizedFileURL)
        XCTAssertEqual(pending.first?.text, "edited")
    }

    func testResnapshotReplacesText() throws {
        try store.snapshot(id: "tab1", text: "v1", fileURL: nil)
        try store.snapshot(id: "tab1", text: "v2", fileURL: nil)
        XCTAssertEqual(store.pending().map(\.text), ["v2"])
    }

    func testClearRemovesSnapshot() throws {
        try store.snapshot(id: "tab1", text: "x", fileURL: nil)
        store.clear(id: "tab1")
        XCTAssertTrue(store.pending().isEmpty)
        XCTAssertTrue(RecoveryStore(directory: dir).pending().isEmpty)
    }

    func testClearAllRemovesEverything() throws {
        try store.snapshot(id: "a", text: "1", fileURL: nil)
        try store.snapshot(id: "b", text: "2", fileURL: nil)
        store.clearAll()
        XCTAssertTrue(RecoveryStore(directory: dir).pending().isEmpty)
    }

    func testPendingIgnoresCorruptEntries() throws {
        try store.snapshot(id: "good", text: "ok", fileURL: nil)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE]).write(to: dir.appendingPathComponent("bad.json"))
        XCTAssertEqual(RecoveryStore(directory: dir).pending().map(\.id), ["good"])
    }

    // MARK: - Launch stamping (M-5)

    func testSnapshotStampsCurrentLaunchByDefault() throws {
        try store.snapshot(id: "t", text: "x", fileURL: nil)
        XCTAssertEqual(store.pending().first?.launchID, RecoveryStore.currentLaunchID,
                       "the drain relies on this stamp to tell live state from residue")
    }

    func testExplicitLaunchIDPersistsAcrossReload() throws {
        try store.snapshot(id: "t", text: "x", fileURL: nil, launchID: "previous-launch")
        XCTAssertEqual(RecoveryStore(directory: dir).pending().first?.launchID,
                       "previous-launch")
    }

    /// Snapshots written by a pre-stamp build must stay recoverable: the
    /// missing field decodes as nil, which the drain treats as residue.
    func testPreStampRecordDecodesWithNilLaunchID() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = #"{"id":"old","text":"from an old build","savedAt":0}"#
        try legacy.data(using: .utf8)!.write(to: dir.appendingPathComponent("old.json"))
        let record = try XCTUnwrap(store.pending().first)
        XCTAssertEqual(record.id, "old")
        XCTAssertNil(record.launchID)
    }
}
