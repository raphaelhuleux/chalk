import XCTest
import ChalkKit
@testable import Chalk

/// The sandboxed Mac App Store build can lose access to a bookmarked folder
/// (sandbox transition from an unsandboxed install, or the folder vanished).
/// Those Locations must stay visible in the Library flagged for re-grant
/// instead of silently disappearing.
final class LocationStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var bookmarks: BookmarkStore!

    override func setUpWithError() throws {
        let suite = "chalk-locstore-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        bookmarks = BookmarkStore(defaults: defaults, key: "locations")
    }

    private func persist(_ records: [LocationRecord]) throws {
        defaults.set(try JSONEncoder().encode(records), forKey: "locations")
    }

    func testUnresolvableRecordSurfacesAsNeedsReauthorization() throws {
        // Garbage bookmark data: resolution fails outright.
        try persist([LocationRecord(id: "dead", name: "Notes", bookmark: Data([0x00, 0x01]))])

        let store = LocationStore(bookmarks: bookmarks)
        let locations = store.locations()

        XCTAssertEqual(locations.map(\.id), ["dead"], "dead Locations must stay visible")
        XCTAssertEqual(locations.first?.name, "Notes")
        XCTAssertEqual(locations.first?.needsReauthorization, true)
    }

    /// A picked folder that could not be stored must be reported, not
    /// dropped: the caller tells the user.
    func testAddReportsAFolderItCouldNotStore() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-add-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let blob = Data("not json".utf8)
        defaults.set(blob, forKey: "locations") // unreadable: BookmarkStore refuses to write

        let store = LocationStore(bookmarks: bookmarks)

        XCTAssertFalse(store.add(url: folder))
        XCTAssertEqual(defaults.data(forKey: "locations"), blob)
    }

    func testAddReportsSuccess() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-add-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = LocationStore(bookmarks: bookmarks)

        XCTAssertTrue(store.add(url: folder))
        XCTAssertEqual(store.locations().count, 1)
    }

    func testReauthorizeRepairsLocation() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-reauth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try persist([LocationRecord(id: "dead", name: "Notes", bookmark: Data([0x00, 0x01]))])
        let store = LocationStore(bookmarks: bookmarks)
        XCTAssertEqual(store.locations().first?.needsReauthorization, true)

        // The user re-picked the folder: the record heals in place.
        store.reauthorize(id: "dead", with: folder)
        let healed = store.locations()
        XCTAssertEqual(healed.map(\.id), ["dead"])
        XCTAssertEqual(healed.first?.needsReauthorization, false)
        XCTAssertEqual(
            healed.first?.url.standardizedFileURL.resolvingSymlinksInPath(),
            folder.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    func testHealthyLocationIsNotFlagged() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-healthy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = LocationStore(bookmarks: bookmarks)
        try bookmarks.add(url: folder, name: "Notes", id: "ok")
        XCTAssertEqual(store.locations().first?.needsReauthorization, false)
    }

    // MARK: - Granting the same folder twice

    /// Picking a folder that is already a Location must re-grant it, not stack
    /// a second identical row. The screenshot audit found this the hard way:
    /// six runs of the same fixture seeding left nine "AuditFixtures" rows in
    /// the Library, each a separate record over the same path.
    func testAddingTheSameFolderTwiceKeepsOneLocation() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-dupe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = LocationStore(bookmarks: bookmarks)
        store.add(url: folder)
        store.add(url: folder)

        XCTAssertEqual(store.locations().count, 1, "the same folder must not stack rows")
        XCTAssertEqual(bookmarks.records().count, 1, "and must not stack bookmark records")
    }

    /// The re-grant path: a Location that resolves but lost access heals when
    /// the user picks the same folder again through "Add Location" (the same
    /// gesture as the row's own re-grant), instead of leaving the dead row
    /// beside a live copy of the same folder.
    func testAddingAFolderThatLostAccessHealsTheExistingRow() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-regrant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = LocationStore(bookmarks: bookmarks)
        try bookmarks.add(url: folder, name: folder.lastPathComponent, id: "stale")

        store.add(url: folder)

        XCTAssertEqual(store.locations().map(\.id), ["stale"], "the row heals in place")
    }

    /// No built-in folder: a window starts with exactly the folders it was given.
    func testANewStoreHasNoLocations() {
        XCTAssertTrue(LocationStore(bookmarks: bookmarks).locations().isEmpty)
    }

    /// Two windows adding the same folder keep separate lists: removing it from one leaves the other.
    func testWindowsKeepSeparateLists() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-two-windows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = LocationStore(bookmarks: WindowLocations.store(
            forWindow: "A", isRestoredWindow: false, defaults: defaults))
        let b = LocationStore(bookmarks: WindowLocations.store(
            forWindow: "B", isRestoredWindow: false, defaults: defaults))

        a.add(url: folder)
        XCTAssertEqual(a.locations().count, 1)
        XCTAssertTrue(b.locations().isEmpty, "adding to one window must not touch another")
        b.add(url: folder)
        a.remove(id: try XCTUnwrap(a.locations().first?.id))
        XCTAssertEqual(b.locations().count, 1)
    }
}
