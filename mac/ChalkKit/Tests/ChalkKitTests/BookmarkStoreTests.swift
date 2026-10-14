import XCTest
@testable import ChalkKit

final class BookmarkStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: BookmarkStore!
    private var folder: URL!

    override func setUpWithError() throws {
        // Isolated defaults per test run.
        let suite = "chalk-bookmark-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = BookmarkStore(defaults: defaults, key: "locations")
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-loc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testStartsEmpty() {
        XCTAssertTrue(store.records().isEmpty)
    }

    func testAddPersistsAndResolves() throws {
        let record = try store.add(url: folder, name: "Notes", id: "loc1")
        XCTAssertEqual(store.records(), [record])

        // A fresh store over the same defaults sees the persisted record.
        let reopened = BookmarkStore(defaults: defaults, key: "locations")
        let resolved = try XCTUnwrap(reopened.resolve(record))
        XCTAssertEqual(resolved.url.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertFalse(resolved.isStale)
    }

    func testRemove() throws {
        try store.add(url: folder, name: "Notes", id: "loc1")
        store.remove(id: "loc1")
        XCTAssertTrue(store.records().isEmpty)
    }

    /// Stored Locations that cannot be decoded (a newer build's format, a
    /// damaged sync) must survive: the next add or remove used to write a
    /// fresh array over them, dropping every bookmark.
    func testAnUnreadableStoreIsNeverOverwritten() throws {
        let blob = Data("not json".utf8)
        defaults.set(blob, forKey: "locations")

        XCTAssertEqual(store.records(), [])
        XCTAssertThrowsError(try store.add(url: folder, name: "Notes", id: "loc1")) {
            XCTAssertEqual($0 as? BookmarkStore.StoreError, .unreadable)
        }
        store.remove(id: "loc1")
        store.refresh(id: "loc1", with: folder)

        XCTAssertEqual(defaults.data(forKey: "locations"), blob)
    }

    func testInMemoryStoreKeepsRecordsWithoutDefaults() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-mem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let memory = BookmarkStore.inMemory()
        try memory.add(url: folder, name: "Notes", id: "m1")
        XCTAssertEqual(memory.records().map(\.id), ["m1"])
        memory.remove(id: "m1")
        XCTAssertEqual(memory.records(), [])
    }

    func testAddCreatesSecurityScopedBookmarkOnMac() throws {
        // The Mac App Store build is sandboxed: persisted folder access only
        // survives relaunch if the bookmark carries security scope. Resolving
        // with .withSecurityScope throws on plain bookmark data, so a
        // successful scoped resolve proves the scope was captured at creation.
        let record = try store.add(url: folder, name: "Notes", id: "loc1")
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: record.bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        XCTAssertEqual(url.standardizedFileURL, folder.standardizedFileURL)
    }

    func testLegacyUnscopedBookmarkStillResolvesAndFlagsRefresh() throws {
        // Records persisted by pre-sandbox builds hold plain bookmarks. They
        // must keep resolving (fallback path), and report stale so the caller
        // upgrades them to scoped bookmarks via refresh().
        let legacy = LocationRecord(id: "old", name: "Old", bookmark: try folder.bookmarkData())
        let data = try JSONEncoder().encode([legacy])
        defaults.set(data, forKey: "locations")

        let resolved = try XCTUnwrap(store.resolve(legacy))
        XCTAssertEqual(resolved.url.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertTrue(resolved.isStale, "legacy bookmarks should be flagged for re-bookmarking")
    }

    func testMultipleLocations() throws {
        let other = folder.deletingLastPathComponent()
            .appendingPathComponent("chalk-loc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }

        try store.add(url: folder, name: "A", id: "a")
        try store.add(url: other, name: "B", id: "b")
        XCTAssertEqual(store.records().map(\.id), ["a", "b"])
    }
}
