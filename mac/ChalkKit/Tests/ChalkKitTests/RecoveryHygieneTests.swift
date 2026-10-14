import XCTest
@testable import ChalkKit

/// The Privacy screen has to state, truthfully, how much unsaved text Chalk is
/// holding on the user's behalf and offer to delete it. That needs three things
/// the store did not have: a count that does not read every file, a size, and a
/// delete that cannot disarm the crash net for windows that are dirty right now.
final class RecoveryHygieneTests: XCTestCase {
    private var dir: URL!
    private var store: RecoveryStore!
    private let previousLaunch = "launch-before-this-one"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-hygiene-\(UUID().uuidString)")
        store = RecoveryStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Make a snapshot look old both ways it can be judged: the `savedAt` the
    /// record carries, which is what `purge` reads for a decodable file, and
    /// the file's mtime, which is the fallback for one that will not decode.
    /// Ageing only the mtime would leave the two disagreeing and the test
    /// asserting against a field nothing consults.
    private func age(_ id: String, days: Int) throws {
        let url = dir.appendingPathComponent("\(id).json")
        let when = Date().addingTimeInterval(-Double(days) * 86_400)

        var json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as! [String: Any]
        // JSONEncoder's default date strategy is seconds since the reference
        // date, so the stored field is a raw number, not a formatted string.
        json["savedAt"] = when.timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        try FileManager.default.setAttributes([.modificationDate: when],
                                              ofItemAtPath: url.path)
    }

    // MARK: - counting and sizing

    func testAnEmptyStoreCountsZeroAndUsesNothing() {
        XCTAssertEqual(store.pendingCount(), 0)
        XCTAssertEqual(store.usage(), 0)
        XCTAssertNil(store.oldestPendingDate())
    }

    func testCountMatchesPendingWithoutDecodingAnything() throws {
        try store.snapshot(id: "a", text: "one", fileURL: nil)
        try store.snapshot(id: "b", text: "two", fileURL: nil)
        XCTAssertEqual(store.pendingCount(), 2)
        XCTAssertEqual(store.pendingCount(), store.pending().count)
    }

    /// The reason this exists: `pending()` materializes every unsaved
    /// document's full text just to answer "how many?". Asking that question on
    /// a Settings screen must not pull a 40 MB thesis into memory.
    func testCountingDoesNotRequireADecodableFile() throws {
        try store.snapshot(id: "good", text: "fine", fileURL: nil)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("broken.json"))

        XCTAssertEqual(store.pendingCount(), 2, "a corrupt file is still a file on disk")
        XCTAssertEqual(store.pending().count, 1, "but it is not recoverable")
    }

    func testUsageGrowsWithTheTextItHolds() throws {
        try store.snapshot(id: "a", text: "small", fileURL: nil)
        let small = store.usage()
        try store.snapshot(id: "b", text: String(repeating: "x", count: 50_000), fileURL: nil)
        XCTAssertGreaterThan(store.usage(), small + 40_000)
    }

    func testOldestReportsTheEarliestSnapshot() throws {
        try store.snapshot(id: "new", text: "n", fileURL: nil)
        try store.snapshot(id: "old", text: "o", fileURL: nil)
        try age("old", days: 9)

        let oldest = try XCTUnwrap(store.oldestPendingDate())
        XCTAssertEqual(oldest.timeIntervalSinceNow, -9 * 86_400, accuracy: 3_600)
    }

    // MARK: - deleting, without disarming the net

    /// The load-bearing one. `clearAll()` deletes the whole directory,
    /// including snapshots this launch wrote seconds ago for windows that are
    /// dirty on screen right now. Wiring a Settings button to it would silently
    /// disarm the crash net mid-session, and the user would find out by losing
    /// work later.
    func testClearingPreviousLaunchesKeepsThisLaunchsSnapshots() throws {
        try store.snapshot(id: "live", text: "typing right now", fileURL: nil)
        try store.snapshot(id: "residue", text: "from the crash", fileURL: nil,
                           launchID: previousLaunch)

        XCTAssertEqual(store.clearPreviousLaunches(), 1)
        XCTAssertEqual(store.pending().map(\.id), ["live"])
    }

    func testClearingPreviousLaunchesOnAFreshSessionRemovesEverythingItShould() throws {
        try store.snapshot(id: "a", text: "x", fileURL: nil, launchID: previousLaunch)
        try store.snapshot(id: "b", text: "y", fileURL: nil, launchID: "older-still")

        XCTAssertEqual(store.clearPreviousLaunches(), 2)
        XCTAssertTrue(store.pending().isEmpty)
    }

    /// A snapshot from a build that predates launch stamping decodes with a nil
    /// launch id. It is by definition not from this launch, so it goes.
    func testAPreStampSnapshotCountsAsAPreviousLaunch() throws {
        try store.snapshot(id: "ancient", text: "x", fileURL: nil)
        let url = dir.appendingPathComponent("ancient.json")
        let stripped = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as! [String: Any]
        var without = stripped
        without.removeValue(forKey: "launchID")
        try JSONSerialization.data(withJSONObject: without).write(to: url)

        XCTAssertEqual(store.clearPreviousLaunches(), 1)
        XCTAssertTrue(store.pending().isEmpty)
    }

    /// A file whose JSON will not decode has no launch id, so it cannot be
    /// this launch's. Left alone would mean corrupt files accumulate forever
    /// with no way to clear them.
    func testAnUndecodableFileCountsAsAPreviousLaunch() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("broken.json"))

        XCTAssertEqual(store.clearPreviousLaunches(), 1)
        XCTAssertEqual(store.pendingCount(), 0)
    }

    func testClearingAnEmptyStoreIsHarmless() {
        XCTAssertEqual(store.clearPreviousLaunches(), 0)
    }

    /// Clearing must not create the directory as a side effect of being asked
    /// about a store that has never been written to.
    func testAskingAboutAStoreThatDoesNotExistYetAnswersZero() {
        let missing = RecoveryStore(directory: dir.appendingPathComponent("nope"))
        XCTAssertEqual(missing.pendingCount(), 0)
        XCTAssertEqual(missing.usage(), 0)
        XCTAssertEqual(missing.clearPreviousLaunches(), 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("nope").path))
    }
}
