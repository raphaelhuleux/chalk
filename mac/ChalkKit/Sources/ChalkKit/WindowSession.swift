import Foundation

/// A window's restorable state, carried in the scene's `NSUserActivity`.
/// The caller excludes drafts: they die with the window (no autosave).
public struct WindowSession: Codable, Equatable {
    public struct TabRecord: Codable, Equatable {
        public let path: String
        /// Needed for files opened from Finder/Files, whose scope dies with the
        /// process; captured for every tab so restore never depends on
        /// Location-resolution order.
        public let bookmark: Data?

        public init(path: String, bookmark: Data?) {
            self.path = path
            self.bookmark = bookmark
        }
    }

    public var tabs: [TabRecord]
    public var activeIndex: Int?
    public var isSidebarVisible: Bool
    /// The persistent outline panel (⌘K). Optional on decode, default closed.
    public var isOutlineVisible: Bool

    public init(tabs: [TabRecord], activeIndex: Int?, isSidebarVisible: Bool,
                isOutlineVisible: Bool = false) {
        self.tabs = tabs
        // Clamp: a stale index would crash the restore path.
        if let index = activeIndex, tabs.indices.contains(index) {
            self.activeIndex = index
        } else {
            self.activeIndex = tabs.isEmpty ? nil : 0
        }
        self.isSidebarVisible = isSidebarVisible
        self.isOutlineVisible = isOutlineVisible
    }

    private enum CodingKeys: String, CodingKey {
        case tabs, activeIndex, isSidebarVisible, isOutlineVisible
    }

    /// Routes through the clamping init.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tabs: try container.decode([TabRecord].self, forKey: .tabs),
            activeIndex: try container.decodeIfPresent(Int.self, forKey: .activeIndex),
            isSidebarVisible: try container.decode(Bool.self, forKey: .isSidebarVisible),
            isOutlineVisible: try container.decodeIfPresent(Bool.self, forKey: .isOutlineVisible) ?? false)
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public init?(data: Data) {
        guard let decoded = try? JSONDecoder().decode(WindowSession.self, from: data) else {
            return nil
        }
        self = decoded
    }
}

/// Bookmark creation and resolution, shared by tab restoration and
/// BookmarkStore's Locations.
public enum FileBookmark {
    /// The sandboxed build keeps file and folder access across relaunches
    /// only via scoped bookmarks.
    private static let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]

    public static func data(for url: URL) throws -> Data {
        try url.bookmarkData(options: creationOptions)
    }

    public static func make(for url: URL) -> Data? {
        try? data(for: url)
    }

    /// On `isStale`, the caller re-bookmarks while it has access.
    public static func resolveReportingStaleness(_ data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        if let url = try? URL(resolvingBookmarkData: data, options: resolutionOptions,
                              relativeTo: nil, bookmarkDataIsStale: &isStale) {
            return (url, isStale)
        }
        // Unscoped bookmarks (unsandboxed or pre-sandbox builds) fail the
        // scoped resolve: report stale so the caller upgrades them.
        guard resolutionOptions != [], let url = try? URL(
            resolvingBookmarkData: data, options: [],
            relativeTo: nil, bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return (url, true)
    }

    public static func resolve(_ data: Data) -> URL? {
        resolveReportingStaleness(data)?.url
    }
}
