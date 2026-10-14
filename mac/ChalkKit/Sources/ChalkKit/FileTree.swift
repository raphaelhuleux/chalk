import Foundation

/// How the Library opens a listed file: documents in an editor tab, binary
/// assets in a Quick Look preview.
public enum FileKind: Equatable {
    case document
    case asset
}

/// One entry in the Library file tree.
public struct FileNode: Equatable, Hashable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool

    public init(url: URL, name: String, isDirectory: Bool) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// What the editor's completion popup can ask the host to list: what a LaTeX
/// or markdown argument can point at (unlike `FileKind`, how a row opens).
public enum WorkspaceFileKind: String, Codable, CaseIterable, Sendable {
    case image
    case document
    case bib
}

/// Directory enumeration for the Library: folders, documents and embeddable
/// assets, folders first, skipping hidden entries. Lazy: `children` per
/// expanded folder.
public enum FileTree {
    public static let editableExtensions: Set<String> = ["md", "tex", "qmd"]

    /// Must equal the set `AssetKind` resolves, so a row never names a file
    /// the editor cannot render (`FileTreeTests` pins this).
    public static let previewableExtensions: Set<String> = ["png", "jpg", "jpeg", "pdf"]

    /// Bibliography sources for `\cite{` completion. Kept separate: the other
    /// two sets are pinned to what renders and what a tab can open.
    public static let bibliographyExtensions: Set<String> = ["bib"]

    /// Extensions a listing request covers.
    public static func extensions(for kinds: [WorkspaceFileKind]) -> Set<String> {
        var set: Set<String> = []
        for kind in kinds {
            switch kind {
            case .image: set.formUnion(previewableExtensions)
            case .document: set.formUnion(editableExtensions)
            case .bib: set.formUnion(bibliographyExtensions)
            }
        }
        return set
    }

    /// Document-relative paths of files of `kinds` under `directory`, for
    /// path completion. Bounded: the popup shows a screenful, and the result
    /// crosses an IPC boundary on every listing.
    public static func relativePaths(
        in directory: URL,
        kinds: [WorkspaceFileKind],
        fileManager: FileManager = .default,
        maxDepth: Int = 6,
        limit: Int = 500
    ) -> [String] {
        let wanted = extensions(for: kinds)
        guard !wanted.isEmpty else { return [] }

        var paths: [String] = []
        func walk(_ dir: URL, prefix: String, depth: Int) {
            guard depth <= maxDepth, paths.count < limit else { return }
            let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
            guard let entries = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { return }

            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if paths.count >= limit { return }
                let values = try? url.resourceValues(forKeys: Set(keys))
                let name = values?.name ?? url.lastPathComponent
                if values?.isDirectory ?? false {
                    walk(url, prefix: prefix + name + "/", depth: depth + 1)
                } else if wanted.contains(url.pathExtension.lowercased()) {
                    paths.append(prefix + name)
                }
            }
        }
        walk(directory, prefix: "", depth: 0)
        return paths
    }

    /// How the hosts should open `url`, or nil when the Library ignores it.
    public static func kind(of url: URL) -> FileKind? {
        let ext = url.pathExtension.lowercased()
        if editableExtensions.contains(ext) { return .document }
        if previewableExtensions.contains(ext) { return .asset }
        return nil
    }

    public static func children(of directory: URL, fileManager: FileManager = .default) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var nodes: [FileNode] = []
        for url in entries {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            let name = values?.name ?? url.lastPathComponent
            if isDir {
                nodes.append(FileNode(url: url, name: name, isDirectory: true))
            } else if kind(of: url) != nil {
                nodes.append(FileNode(url: url, name: name, isDirectory: false))
            }
        }

        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory } // folders first
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Every listed file under `directory`, recursively, for Quick Open.
    public static func allFiles(
        in directory: URL,
        fileManager: FileManager = .default,
        maxDepth: Int = 8
    ) -> [FileNode] {
        var files: [FileNode] = []
        func walk(_ dir: URL, depth: Int) {
            guard depth <= maxDepth else { return }
            for node in children(of: dir, fileManager: fileManager) {
                if node.isDirectory {
                    walk(node.url, depth: depth + 1)
                } else {
                    files.append(node)
                }
            }
        }
        walk(directory, depth: 0)
        return files
    }
}
