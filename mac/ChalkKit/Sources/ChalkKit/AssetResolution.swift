import Foundation

/// What the live preview can display. `pdf` has no `<img>` MIME type — the
/// app layer rasterizes page 1 to PNG before shipping it to the webview.
public enum AssetKind: Equatable {
    case png
    case jpeg
    case pdf

    public var mimeType: String? {
        switch self {
        case .png: return "image/png"
        case .jpeg: return "image/jpeg"
        case .pdf: return nil
        }
    }

    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        case "pdf": self = .pdf
        default: return nil
        }
    }
}

/// Pure path resolution for the image live preview (the editor's
/// `resolve-asset` bridge): a document-relative `src` to the file URL to load,
/// honoring `\graphicspath` and pdflatex-style extension probing. File IO and
/// PDF rasterization live in the app target's AssetLoader.
public enum AssetResolution {
    /// Raw file cap. Anything larger resolves nil (the editor shows its
    /// missing placeholder) rather than shipping a ~33 MB base64 string
    /// through `evaluateJavaScript`.
    public static let maxAssetBytes = 25 * 1024 * 1024

    /// pdflatex's lookup order for `\includegraphics{plot}` without an
    /// extension: vector first.
    static let probeExtensions = ["pdf", "png", "jpg", "jpeg"]

    /// Directories declared by `\graphicspath{{figures/}{plots/}}`, in
    /// declaration order. Best-effort (no TeX expansion): a wrong candidate
    /// only costs a failed existence check.
    public static func graphicsPaths(inTeX source: String) -> [String] {
        // Runs on every resolve-asset request; most documents never declare
        // one. Same matcher as the scan below, so the shortcut can't diverge.
        guard source.range(of: "\\graphicspath") != nil else { return [] }
        let stripped = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripComment(String($0)) }
            .joined(separator: "\n")

        var dirs: [String] = []
        var search = stripped.startIndex
        while let cmd = stripped.range(of: "\\graphicspath", range: search ..< stripped.endIndex) {
            var i = cmd.upperBound
            while i < stripped.endIndex, stripped[i].isWhitespace { i = stripped.index(after: i) }
            guard i < stripped.endIndex, stripped[i] == "{" else {
                search = cmd.upperBound
                continue
            }
            i = stripped.index(after: i)
            scan: while i < stripped.endIndex {
                while i < stripped.endIndex, stripped[i].isWhitespace { i = stripped.index(after: i) }
                guard i < stripped.endIndex, stripped[i] != "}" else {
                    if i < stripped.endIndex { i = stripped.index(after: i) }
                    break scan
                }
                guard stripped[i] == "{" else { break scan }
                i = stripped.index(after: i)
                var dir = ""
                while i < stripped.endIndex, stripped[i] != "}", stripped[i] != "\n" {
                    dir.append(stripped[i])
                    i = stripped.index(after: i)
                }
                guard i < stripped.endIndex, stripped[i] == "}" else { break scan }
                i = stripped.index(after: i)
                if !dir.isEmpty { dirs.append(dir) }
            }
            search = i
        }
        return dirs
    }

    /// Absolute figure directories declared by `\graphicspath` in `files`,
    /// each resolved against the DECLARING file's directory (LaTeX resolves
    /// against the compilation directory, so re-anchoring a root's entry to
    /// an `\input`-ed subfile would be wrong). Deduplicated.
    public static func graphicsSearchDirs(declaredIn files: [(url: URL, source: String)]) -> [URL] {
        var seen = Set<String>()
        var dirs: [URL] = []
        for file in files {
            let base = file.url.deletingLastPathComponent()
            for entry in graphicsPaths(inTeX: file.source) {
                let dir = entry.hasPrefix("/")
                    ? URL(fileURLWithPath: entry, isDirectory: true)
                    : base.appendingPathComponent(entry, isDirectory: true)
                guard seen.insert(dir.standardizedFileURL.path).inserted else { continue }
                dirs.append(dir)
            }
        }
        return dirs
    }

    /// The Library Location that bounds the figure search: the deepest of
    /// `roots` containing `documentDirectory`, or nil when the document sits
    /// outside every Location. Matching is by path component, so `/proj`
    /// never swallows `/proj-old`.
    public static func workspaceRoot(for documentDirectory: URL, roots: [URL]) -> URL? {
        let docPath = documentDirectory.standardizedFileURL.path
        return roots
            .filter { root in
                let rootPath = root.standardizedFileURL.path
                return docPath == rootPath || docPath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
            }
            .max { $0.standardizedFileURL.path.count < $1.standardizedFileURL.path.count }
    }

    /// Directories strictly above `documentDirectory` up to and including
    /// `root`, nearest first. Empty unless `root` is a proper ancestor, so the
    /// search never leaves the folder the sandbox was granted.
    public static func ancestorDirectories(of documentDirectory: URL, upTo root: URL?) -> [URL] {
        guard let root else { return [] }
        let rootPath = root.standardizedFileURL.path
        var current = documentDirectory.standardizedFileURL
        var dirs: [URL] = []
        while current.path != rootPath {
            let parent = current.deletingLastPathComponent().standardizedFileURL
            // Reached the filesystem root without meeting `root`: not an ancestor.
            guard parent.path != current.path else { return [] }
            current = parent
            dirs.append(current)
        }
        return dirs
    }

    /// Resolve `src` to the file to load and its kind, or nil. Base
    /// directories are tried dir-major: the document's own, each graphicspath
    /// entry, `extraSearchDirs` (declared by a root file this one is
    /// `\input`-ed into), then each ancestor up to `workspaceRoot`. Declared
    /// directories outrank the blind climb.
    ///
    /// The ancestor climb stands in for `TEXINPUTS`, which projects set
    /// outside the document (`.latexmkrc`, env var). `\graphicspath` entries
    /// are not re-applied to ancestors.
    public static func resolveAsset(
        src: String,
        documentDirectory: URL,
        graphicsPaths: [String],
        allowExtensionProbing: Bool,
        workspaceRoot: URL? = nil,
        extraSearchDirs: [URL] = [],
        fileExists: (URL) -> Bool
    ) -> (url: URL, kind: AssetKind)? {
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Markdown srcs arrive percent-encoded (`my%20plot.png`); a literal
        // `%` that isn't valid encoding decodes to nil → keep the original.
        let path = trimmed.removingPercentEncoding ?? trimmed

        let isAbsolute = path.hasPrefix("/")
        let baseDirs: [URL?] = isAbsolute
            ? [nil]
            : [documentDirectory]
                + graphicsPaths.map { entry in
                    entry.hasPrefix("/")
                        ? URL(fileURLWithPath: entry, isDirectory: true)
                        : documentDirectory.appendingPathComponent(entry, isDirectory: true)
                }
                + extraSearchDirs
                + ancestorDirectories(of: documentDirectory, upTo: workspaceRoot)

        func candidate(_ base: URL?, _ relative: String) -> URL {
            base.map { $0.appendingPathComponent(relative) } ?? URL(fileURLWithPath: relative)
        }

        let ext = (path as NSString).pathExtension
        if !ext.isEmpty {
            guard let kind = AssetKind(fileExtension: ext) else { return nil }
            for base in baseDirs {
                let url = candidate(base, path)
                if fileExists(url) { return (url, kind) }
            }
            return nil
        }

        guard allowExtensionProbing else { return nil }
        for base in baseDirs {
            for probe in probeExtensions {
                let url = candidate(base, path).appendingPathExtension(probe)
                if fileExists(url), let kind = AssetKind(fileExtension: probe) {
                    return (url, kind)
                }
            }
        }
        return nil
    }

    /// `data:{mime};base64,...` for bytes read off disk.
    public static func dataURL(mime: String, bytes: Data) -> String {
        "data:\(mime);base64,\(bytes.base64EncodedString())"
    }

    /// Text before the first unescaped `%` (LaTeX line comment).
    private static func stripComment(_ line: String) -> String {
        var previous: Character?
        for index in line.indices {
            let c = line[index]
            if c == "%", previous != "\\" { return String(line[..<index]) }
            previous = c
        }
        return line
    }
}
