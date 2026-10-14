import Foundation

/// Which window takes a file or folder handed to the app from outside (Finder, Raycast, `open -a`),
/// VS Code style. Paths are `URL.fileIdentity` strings; `windowRoots[i]` is window i's Location roots,
/// frontmost window first so ties go to it.
public enum ExternalOpenRouting {
    /// The window already showing `folder` as one of its roots: it comes forward instead of a second
    /// window opening on the same folder.
    public static func windowShowing(folder: String, windowRoots: [[String]]) -> Int? {
        windowRoots.firstIndex { $0.contains(folder) }
    }

    /// The window whose roots contain `file`. Nested roots across windows: the deepest one wins.
    public static func windowContaining(file: String, windowRoots: [[String]]) -> Int? {
        var best: (index: Int, depth: Int)?
        for (index, roots) in windowRoots.enumerated() {
            for root in roots where isInside(file, root: root) {
                if best == nil || root.count > best!.depth { best = (index, root.count) }
            }
        }
        return best?.index
    }

    static func isInside(_ path: String, root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }
}
