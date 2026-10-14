import Foundation

/// Which directory a sidebar drag-move lands in, Finder-style: a folder row
/// names itself, a file row its parent (how a file gets dragged back out of a
/// folder), no row the Location's top level. Geometry stays in the view
/// controller.
public enum SidebarDropPolicy {
    /// The row under the pointer. The "Empty" sentinel counts as a top-level
    /// `.file`.
    public enum Row: Equatable {
        case folder(URL)
        case file(URL)
    }

    /// Where the drop lands. `.locationRoot` lets the caller light the
    /// Location header, since no row represents the root. Equality compares
    /// normalized paths: "/a/b" and "/a/b/" name the same folder.
    public enum Destination: Equatable {
        case locationRoot
        case folder(URL)

        public static func == (lhs: Destination, rhs: Destination) -> Bool {
            switch (lhs, rhs) {
            case (.locationRoot, .locationRoot): return true
            case (.folder(let a), .folder(let b)):
                return a.standardizedFileURL.path == b.standardizedFileURL.path
            default: return false
            }
        }
    }

    public static func destination(row: Row?, locationRoot: URL) -> Destination {
        guard let row else { return .locationRoot }
        switch row {
        case .folder(let url):
            return directory(url, locationRoot)
        case .file(let url):
            return directory(url.deletingLastPathComponent(), locationRoot)
        }
    }

    /// Compare by path, not `URL`: `deletingLastPathComponent` adds a trailing
    /// slash, making a different `URL` for the same directory.
    private static func directory(_ url: URL, _ locationRoot: URL) -> Destination {
        let directory = url.standardizedFileURL
        if directory.path == locationRoot.standardizedFileURL.path { return .locationRoot }
        return .folder(directory)
    }
}
