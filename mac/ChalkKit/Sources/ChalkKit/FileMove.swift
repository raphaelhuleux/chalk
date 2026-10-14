import Foundation

/// Path arithmetic for the sidebar's rename and drag-move: where an open tab's
/// URL lands after a move, and whether a move is legal.
public enum FileMove {
    /// Map `url` across a move of `from`→`to`: `from` itself or a descendant
    /// is rewritten onto `to`; anything else is nil.
    public static func remap(url: URL, from: URL, to: URL) -> URL? {
        let target = url.standardizedFileURL
        let old = from.standardizedFileURL
        if target == old { return to.standardizedFileURL }
        let oldComponents = old.pathComponents
        let components = target.pathComponents
        guard components.count > oldComponents.count,
              Array(components.prefix(oldComponents.count)) == oldComponents else { return nil }
        var result = to.standardizedFileURL
        for component in components.dropFirst(oldComponents.count) { result.appendPathComponent(component) }
        return result
    }

    /// Whether `source` may move into `directory`. Rejects a no-op and, for a
    /// folder, a move into itself or a descendant. Collisions are the caller's.
    public static func canMove(source: URL, isDirectory: Bool, into directory: URL) -> Bool {
        let src = source.standardizedFileURL
        let target = directory.standardizedFileURL
        // Compare by path: `deletingLastPathComponent` leaves a trailing slash
        // that breaks whole-URL equality.
        if src.deletingLastPathComponent().standardizedFileURL.path == target.path { return false }
        if isDirectory {
            if target.path == src.path { return false }
            let srcComponents = src.pathComponents
            let targetComponents = target.pathComponents
            if targetComponents.count >= srcComponents.count,
               Array(targetComponents.prefix(srcComponents.count)) == srcComponents { return false }
        }
        return true
    }
}
