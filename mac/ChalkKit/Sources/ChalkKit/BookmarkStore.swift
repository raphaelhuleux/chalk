import Foundation

/// A persisted Location: a user-granted folder, stored as a bookmark.
public struct LocationRecord: Codable, Equatable, Hashable {
    public let id: String
    public var name: String
    public var bookmark: Data

    public init(id: String, name: String, bookmark: Data) {
        self.id = id
        self.name = name
        self.bookmark = bookmark
    }
}

/// Persists and resolves one window's Location bookmarks (see `WindowLocations`). The caller calls
/// `startAccessingSecurityScopedResource()` on the resolved URL.
public final class BookmarkStore {
    /// nil: held in memory only (`inMemory()`).
    private let defaults: UserDefaults?
    private let key: String
    private var memory: Data?
    /// The decoded list, kept until this store writes: it is the only writer
    /// of its key, and `records()` is read on every layout, resolve and reload.
    private var decoded: [LocationRecord]??

    public init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    private init() {
        defaults = nil
        key = ""
    }

    /// A store that never touches UserDefaults: for windows built outside a scene (tests), which must
    /// not write the installed app's bookmarks.
    public static func inMemory() -> BookmarkStore { BookmarkStore() }

    private var storedData: Data? {
        get {
            guard let defaults else { return memory }
            return defaults.data(forKey: key)
        }
        set {
            decoded = nil
            if let defaults { defaults.set(newValue, forKey: key) } else { memory = newValue }
        }
    }

    /// Why `add` refused to write.
    public enum StoreError: Error, Equatable {
        /// Stored Locations could not be decoded; writing would erase them.
        case unreadable
    }

    public func records() -> [LocationRecord] {
        loadRecords() ?? []
    }

    /// `[]` when nothing is stored; nil when data exists but cannot be decoded.
    /// Mutations treat nil as hands-off: overwriting would lose every bookmark,
    /// which a later build might still read.
    private func loadRecords() -> [LocationRecord]? {
        if let decoded { return decoded }
        let records: [LocationRecord]?
        if let data = storedData {
            records = try? JSONDecoder().decode([LocationRecord].self, from: data)
        } else {
            records = []
        }
        decoded = .some(records)
        return records
    }

    private func save(_ records: [LocationRecord]) {
        if let data = try? JSONEncoder().encode(records) {
            storedData = data
        }
    }

    /// Bookmark `url` and append it; the caller dedupes. Throws
    /// `StoreError.unreadable`, writing nothing, if stored Locations are
    /// unreadable.
    @discardableResult
    public func add(url: URL, name: String, id: String = UUID().uuidString) throws -> LocationRecord {
        guard var current = loadRecords() else { throw StoreError.unreadable }
        let bookmark = try FileBookmark.data(for: url)
        let record = LocationRecord(id: id, name: name, bookmark: bookmark)
        current.append(record)
        save(current)
        return record
    }

    /// A no-op while the stored Locations cannot be read (see `loadRecords`).
    public func remove(id: String) {
        guard let current = loadRecords() else { return }
        save(current.filter { $0.id != id })
    }

    /// Resolve a record to a URL. On `isStale`, the caller re-bookmarks via
    /// `refresh`.
    public func resolve(_ record: LocationRecord) -> (url: URL, isStale: Bool)? {
        FileBookmark.resolveReportingStaleness(record.bookmark)
    }

    /// Replace a record's bookmark after a stale resolution.
    public func refresh(id: String, with url: URL) {
        guard let bookmark = try? FileBookmark.data(for: url),
              var current = loadRecords() else { return }
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        current[index].bookmark = bookmark
        save(current)
    }
}
