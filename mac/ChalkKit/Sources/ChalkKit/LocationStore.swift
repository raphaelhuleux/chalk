import Foundation
import os

private let log = Logger(subsystem: "com.huleux.chalk", category: "library")

/// A folder the sidebar roots a tree at. One that lost access or failed to resolve stays listed,
/// flagged `needsReauthorization`, so the user can re-grant it instead of it vanishing.
public struct Location: Hashable {
    public let id: String
    public let name: String
    public let url: URL
    public var needsReauthorization: Bool = false

    public init(id: String, name: String, url: URL, needsReauthorization: Bool = false) {
        self.id = id
        self.name = name
        self.url = url
        self.needsReauthorization = needsReauthorization
    }
}

/// One window's Locations: the folders the user added to it, persisted as security-scoped bookmarks
/// (`WindowLocations` picks the per-window BookmarkStore). Mutations post `.chalkLibraryDidChange`.
public final class LocationStore {
    private let bookmarks: BookmarkStore
    /// Bookmarks resolved by this window, by record id. `locations()` runs on every reload and each
    /// unbalanced `startAccessingSecurityScopedResource()` leaks a sandbox extension; `releaseScopes()`
    /// gives them back when the window goes away.
    private var resolved: [String: Location] = [:]

    public init(bookmarks: BookmarkStore) {
        self.bookmarks = bookmarks
    }

    /// For a window built outside a scene (tests): nothing is read from or written to UserDefaults.
    public static func detached() -> LocationStore { LocationStore(bookmarks: .inMemory()) }

    /// Records that fail to resolve or grant no access are flagged `needsReauthorization` and never
    /// cached, so a re-grant heals them on next reload.
    public func locations() -> [Location] {
        var result: [Location] = []
        for record in bookmarks.records() {
            if let cached = resolved[record.id] {
                result.append(cached)
                continue
            }
            guard let resolution = bookmarks.resolve(record) else {
                result.append(Location(
                    id: record.id, name: record.name,
                    url: URL(fileURLWithPath: "/.chalk-unresolved/\(record.id)"),
                    needsReauthorization: true))
                continue
            }
            // Enter the scope before refreshing a stale bookmark: in the sandbox, minting
            // `.withSecurityScope` data without an active scope silently fails.
            let accessing = resolution.url.startAccessingSecurityScopedResource() // held for the session
            if resolution.isStale { bookmarks.refresh(id: record.id, with: resolution.url) }
            guard FileManager.default.isReadableFile(atPath: resolution.url.path) else {
                if accessing { resolution.url.stopAccessingSecurityScopedResource() }
                result.append(Location(
                    id: record.id, name: record.name, url: resolution.url,
                    needsReauthorization: true))
                continue
            }
            let location = Location(id: record.id, name: record.name, url: resolution.url)
            resolved[record.id] = location
            result.append(location)
        }
        return result
    }

    /// Persist a folder the user picked; false when it could not be added. A folder that is already a
    /// Location is re-granted in place rather than added twice.
    @discardableResult
    public func add(url: URL) -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        defer { NotificationCenter.default.post(name: .chalkLibraryDidChange, object: self) }

        let target = url.fileIdentity
        if let existing = recordID(matching: target) {
            // Drop the session cache so the next locations() re-resolves the fresh bookmark.
            bookmarks.refresh(id: existing, with: url)
            if let cached = resolved.removeValue(forKey: existing) {
                cached.url.stopAccessingSecurityScopedResource()
            }
            return true
        }
        do {
            try bookmarks.add(url: url, name: url.lastPathComponent)
            return true
        } catch {
            log.error("could not add \(url.lastPathComponent, privacy: .private) to the Library: \(DiagError(error), privacy: .public)")
            return false
        }
    }

    /// An unresolved Location has a placeholder URL and never matches; its own re-grant heals it.
    private func recordID(matching identity: String) -> String? {
        locations().first { $0.url.fileIdentity == identity }?.id
    }

    /// Replace a Location's bookmark with the re-picked folder and drop its session cache.
    public func reauthorize(id: String, with url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        bookmarks.refresh(id: id, with: url)
        if let cached = resolved.removeValue(forKey: id) {
            cached.url.stopAccessingSecurityScopedResource()
        }
        NotificationCenter.default.post(name: .chalkLibraryDidChange, object: self)
    }

    public func remove(id: String) {
        defer { NotificationCenter.default.post(name: .chalkLibraryDidChange, object: self) }
        if let location = resolved.removeValue(forKey: id) {
            location.url.stopAccessingSecurityScopedResource()
        }
        bookmarks.remove(id: id)
    }

    /// Window teardown: end every scope this store entered. The next `locations()` re-enters them.
    public func releaseScopes() {
        for location in resolved.values { location.url.stopAccessingSecurityScopedResource() }
        resolved.removeAll()
    }
}
