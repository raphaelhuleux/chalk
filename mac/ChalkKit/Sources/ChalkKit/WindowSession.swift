import Foundation

/// A window's restorable state, carried in the `WindowSessionJournal`.
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

    /// One side-by-side tab group: its tabs in strip order, the one it shows, its width share
    /// (stored as written; `EditorGroupsLayout` cleans and normalises shares on restore).
    public struct GroupRecord: Codable, Equatable {
        public var tabs: [TabRecord]
        public var activeIndex: Int?
        public var fraction: Double

        public init(tabs: [TabRecord], activeIndex: Int?, fraction: Double = 1) {
            self.tabs = tabs
            // Clamp: a stale index would crash the restore path.
            if let index = activeIndex, tabs.indices.contains(index) {
                self.activeIndex = index
            } else {
                self.activeIndex = tabs.isEmpty ? nil : 0
            }
            self.fraction = fraction
        }

        private enum CodingKeys: String, CodingKey { case tabs, activeIndex, fraction }

        /// Routes through the clamping init.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(tabs: try container.decode([TabRecord].self, forKey: .tabs),
                      activeIndex: try container.decodeIfPresent(Int.self, forKey: .activeIndex),
                      fraction: try container.decodeIfPresent(Double.self, forKey: .fraction) ?? 1)
        }
    }

    /// Leading to trailing; never holds an empty group (a window with no file tabs has none).
    public var groups: [GroupRecord]
    /// The focused group; nil only without groups.
    public var activeGroupIndex: Int?
    public var isSidebarVisible: Bool
    /// The persistent outline panel (⌘K). Optional on decode, default closed.
    public var isOutlineVisible: Bool

    public init(groups: [GroupRecord], activeGroupIndex: Int?, isSidebarVisible: Bool,
                isOutlineVisible: Bool = false) {
        let kept = groups.filter { !$0.tabs.isEmpty }
        self.groups = kept
        // An index into the input; empty groups dropped before it shift it.
        if let index = activeGroupIndex, groups.indices.contains(index), !groups[index].tabs.isEmpty {
            self.activeGroupIndex = groups[..<index].filter { !$0.tabs.isEmpty }.count
        } else {
            self.activeGroupIndex = kept.isEmpty ? nil : 0
        }
        self.isSidebarVisible = isSidebarVisible
        self.isOutlineVisible = isOutlineVisible
    }

    /// One group holding every tab.
    public init(tabs: [TabRecord], activeIndex: Int?, isSidebarVisible: Bool,
                isOutlineVisible: Bool = false) {
        self.init(groups: [GroupRecord(tabs: tabs, activeIndex: activeIndex)], activeGroupIndex: 0,
                  isSidebarVisible: isSidebarVisible, isOutlineVisible: isOutlineVisible)
    }

    /// Every tab, leading group first.
    public var tabs: [TabRecord] { groups.flatMap(\.tabs) }

    /// The focused group's shown tab, as an index into `tabs`.
    public var activeIndex: Int? {
        guard let g = activeGroupIndex, let local = groups[g].activeIndex else { return nil }
        return groups[..<g].reduce(0) { $0 + $1.tabs.count } + local
    }

    private enum CodingKeys: String, CodingKey {
        case groups, activeGroupIndex, isSidebarVisible, isOutlineVisible
        // Records written before tab groups: one strip, at most one tab in a second pane.
        case tabs, activeIndex, splitIndex, splitIsLeading
    }

    /// Routes through the clamping inits. A record without `groups` predates tab groups: its
    /// split tab (if any) becomes a group of its own beside the rest.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let isSidebarVisible = try container.decode(Bool.self, forKey: .isSidebarVisible)
        let isOutlineVisible = try container.decodeIfPresent(Bool.self, forKey: .isOutlineVisible) ?? false
        if let groups = try container.decodeIfPresent([GroupRecord].self, forKey: .groups) {
            self.init(groups: groups,
                      activeGroupIndex: try container.decodeIfPresent(Int.self, forKey: .activeGroupIndex),
                      isSidebarVisible: isSidebarVisible, isOutlineVisible: isOutlineVisible)
            return
        }
        let tabs = try container.decode([TabRecord].self, forKey: .tabs)
        let activeIndex = try container.decodeIfPresent(Int.self, forKey: .activeIndex)
        let splitIndex = try container.decodeIfPresent(Int.self, forKey: .splitIndex)
        let splitIsLeading = try container.decodeIfPresent(Bool.self, forKey: .splitIsLeading) ?? false
        let active = activeIndex.flatMap { tabs.indices.contains($0) ? $0 : nil } ?? (tabs.isEmpty ? nil : 0)
        guard let split = splitIndex, tabs.indices.contains(split), split != active, tabs.count > 1 else {
            self.init(tabs: tabs, activeIndex: active,
                      isSidebarVisible: isSidebarVisible, isOutlineVisible: isOutlineVisible)
            return
        }
        var rest = tabs
        rest.remove(at: split)
        let main = GroupRecord(tabs: rest, activeIndex: active.map { $0 > split ? $0 - 1 : $0 }, fraction: 0.5)
        let side = GroupRecord(tabs: [tabs[split]], activeIndex: 0, fraction: 0.5)
        self.init(groups: splitIsLeading ? [side, main] : [main, side],
                  activeGroupIndex: splitIsLeading ? 1 : 0,
                  isSidebarVisible: isSidebarVisible, isOutlineVisible: isOutlineVisible)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(groups, forKey: .groups)
        try container.encodeIfPresent(activeGroupIndex, forKey: .activeGroupIndex)
        try container.encode(isSidebarVisible, forKey: .isSidebarVisible)
        try container.encode(isOutlineVisible, forKey: .isOutlineVisible)
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
