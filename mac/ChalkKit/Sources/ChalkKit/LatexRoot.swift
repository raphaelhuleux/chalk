import Foundation

/// LaTeX root-file resolution for compile: which file to typeset when a
/// chapter is saved. Swift port of `vscode/src/extension/latex/root-finder.ts`;
/// both run the shared cases in `Tests/fixtures/latex-roots/cases.json`, so a
/// rule change lands in both or the parity tests fail.
///
/// Resolution order (first hit wins):
///   1. `% !TEX root = …` magic comment anywhere in the saved file.
///   2. A configured root.
///   3. The saved file itself, when it declares `\documentclass`.
///   4. Roots (`\documentclass` files) that reach the saved file through
///      their include graph or their last `.fls`, ranked by `rank`.
public enum LatexRoot {
    /// The file system as the finder sees it, injected so tests run without disk.
    public struct FileSystem {
        public var readFile: (String) -> String?
        public var exists: (String) -> Bool
        /// Absolute paths of candidate .tex files (the caller bounds the walk).
        public var listTexFiles: () -> [String]
        /// Absolute input paths from a root's last `.fls`, or [].
        public var flsInputs: (String) -> [String]

        public init(
            readFile: @escaping (String) -> String?,
            exists: @escaping (String) -> Bool,
            listTexFiles: @escaping () -> [String],
            flsInputs: @escaping (String) -> [String] = { _ in [] }
        ) {
            self.readFile = readFile
            self.exists = exists
            self.listTexFiles = listTexFiles
            self.flsInputs = flsInputs
        }
    }

    public struct Options {
        /// Absolute, or relative to `workspaceDir`.
        public var configuredRoot: String?
        public var workspaceDir: String?
        /// The root this file last compiled with this session; wins ties so the
        /// choice does not flip between saves.
        public var preferredRoot: String?

        public init(configuredRoot: String? = nil, workspaceDir: String? = nil, preferredRoot: String? = nil) {
            self.configuredRoot = configuredRoot
            self.workspaceDir = workspaceDir
            self.preferredRoot = preferredRoot
        }
    }

    public struct Result: Equatable {
        public var root: String?
        /// Human-readable trace for the compile log.
        public var reason: String
    }

    /// Include-graph safety bound; a paper project is a handful of files.
    static let maxGraphFiles = 200

    // MARK: - Paths

    /// `path.resolve(base, rel)`: absolute `rel` wins; `.`/`..` collapse.
    static func resolve(_ base: String, _ rel: String) -> String {
        let url = rel.hasPrefix("/")
            ? URL(fileURLWithPath: rel)
            : URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(rel)
        return url.standardizedFileURL.path
    }

    static func dirname(_ path: String) -> String { (path as NSString).deletingLastPathComponent }

    static func withTexExt(_ target: String) -> String {
        (target as NSString).pathExtension.isEmpty ? target + ".tex" : target
    }

    // MARK: - Source scanning

    /// Drop `%` comments, keeping escaped `\%`.
    public static func stripComments(_ tex: String) -> String {
        tex.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            var prev: Character?
            for i in line.indices {
                if line[i] == "%" && prev != "\\" { return line[..<i] }
                prev = line[i]
            }
            return line
        }.joined(separator: "\n")
    }

    static func hasDocumentclass(_ tex: String) -> Bool {
        stripComments(tex).contains("\\documentclass")
    }

    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let magicRoot = regex(#"^\s*%\s*!\s*TEX\s+root\s*=\s*(.+?)\s*$"#, .caseInsensitive)
    private static let inputPattern = regex(#"\\(?:input|include|InputIfFileExists)\s*(?:\{([^}]+)\}|\s([^\s{}%\\]+))"#)
    private static let subfilePattern = regex(#"\\subfile\s*\{([^}]+)\}"#)
    private static let importPattern = regex(#"\\(sub)?(?:import|inputfrom|includefrom)\*?\s*\{([^}]*)\}\s*\{([^}]+)\}"#)

    private static func matches(_ re: NSRegularExpression, in s: String) -> [[String?]] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
        }
    }

    /// A file in the include graph with the directory its includes resolve
    /// against. TeX looks in the compile directory (the root's) first; the
    /// `import` package and `subfiles` add the imported file's directory.
    struct GraphNode {
        var file: String
        var base: String
    }

    private static func inputTargets(_ target: String, _ node: GraphNode, _ rootDir: String) -> [GraphNode] {
        let rel = withTexExt(target.trimmingCharacters(in: .whitespaces))
        let bases = node.base == rootDir ? [rootDir] : [rootDir, node.base]
        return bases.map { GraphNode(file: resolve($0, rel), base: node.base) }
    }

    static func includes(of tex: String, node: GraphNode, rootDir: String) -> [GraphNode] {
        let stripped = stripComments(tex)
        var out: [GraphNode] = []
        for m in matches(inputPattern, in: stripped) {
            guard let target = m[1] ?? m[2] else { continue }
            out += inputTargets(target, node, rootDir)
        }
        for m in matches(subfilePattern, in: stripped) {
            guard let target = m[1] else { continue }
            out += inputTargets(target, node, rootDir).map { GraphNode(file: $0.file, base: dirname($0.file)) }
        }
        // \import{dir}{file} takes dir from the compile directory;
        // \subimport{dir}{file} from the current file's base.
        for m in matches(importPattern, in: stripped) {
            guard let dirArg = m[2], let file = m[3] else { continue }
            let dir = resolve(m[1] != nil ? node.base : rootDir, dirArg.trimmingCharacters(in: .whitespaces))
            out.append(GraphNode(file: resolve(dir, withTexExt(file.trimmingCharacters(in: .whitespaces))), base: dir))
        }
        return out
    }

    /// BFS over `rootFile`'s include closure: each readable file with its
    /// resolved include targets (readable or not).
    static func includeClosure(_ rootFile: String, _ fs: FileSystem) -> [(file: String, includes: [String])] {
        let root = resolve("/", rootFile)
        let rootDir = dirname(root)
        var queue = [GraphNode(file: root, base: rootDir)]
        var visited = Set<String>()
        var out: [(file: String, includes: [String])] = []
        while !queue.isEmpty, visited.count < maxGraphFiles {
            let node = queue.removeFirst()
            guard visited.insert(node.file).inserted else { continue }
            guard let content = fs.readFile(node.file) else { continue }
            let children = includes(of: content, node: node, rootDir: rootDir)
            out.append((node.file, children.map(\.file)))
            queue += children.filter { !visited.contains($0.file) }
        }
        return out
    }

    /// The root plus every readable .tex file its include closure reaches.
    public static func includedTexFiles(_ rootFile: String, _ fs: FileSystem) -> [String] {
        includeClosure(rootFile, fs).map(\.file)
    }

    /// `INPUT` lines of a `.fls` recorder file as absolute paths, relative
    /// ones resolved against its `PWD` line.
    public static func parseFlsInputs(_ fls: String) -> [String] {
        var pwd = ""
        var seen = Set<String>()
        var inputs: [String] = []
        for raw in fls.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("PWD ") {
                pwd = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("INPUT ") {
                let p = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                let abs = resolve(pwd.isEmpty ? "/" : pwd, p)
                if seen.insert(abs).inserted { inputs.append(abs) }
            }
        }
        return inputs
    }

    // MARK: - Ranking

    /// Directory hops from the root's folder to the saved file's.
    static func distance(_ root: String, _ saved: String) -> Int {
        let a = dirname(root).split(separator: "/")
        let b = dirname(saved).split(separator: "/")
        let common = zip(a, b).prefix { $0 == $1 }.count
        return (a.count - common) + (b.count - common)
    }

    /// Several roots reach the file (a shared chapter in `main.tex` and
    /// `slides.tex`): this session's previous choice, then a root whose last
    /// compile read the file, then the nearest folder, then name.
    static func rank(_ roots: [(file: String, viaFls: Bool)], saved: String, preferred: String?) -> [(file: String, viaFls: Bool)] {
        roots.sorted { a, b in
            let ka = (a.file == preferred ? 0 : 1, a.viaFls ? 0 : 1, distance(a.file, saved))
            let kb = (b.file == preferred ? 0 : 1, b.viaFls ? 0 : 1, distance(b.file, saved))
            if ka != kb { return ka < kb }
            return a.file < b.file
        }
    }

    // MARK: - Entry point

    public static func find(saved savedPath: String, fs: FileSystem, options: Options = Options()) -> Result {
        let saved = resolve("/", savedPath)
        let savedContent = fs.readFile(saved)
        let savedName = (saved as NSString).lastPathComponent

        // 1. Magic comment.
        if let savedContent {
            for line in savedContent.split(separator: "\n", omittingEmptySubsequences: false) {
                guard let m = matches(magicRoot, in: String(line)).first, let target = m[1] else { continue }
                for candidate in [target, target + ".tex"] {
                    let abs = resolve(dirname(saved), candidate)
                    if fs.exists(abs) { return Result(root: abs, reason: "magic comment in \(savedName)") }
                }
                return Result(root: nil, reason: "magic comment points at missing file: \(target)")
            }
        }

        // 2. Configured root.
        if let configured = options.configuredRoot, !configured.isEmpty {
            let abs = resolve(options.workspaceDir ?? dirname(saved), configured)
            if fs.exists(abs) { return Result(root: abs, reason: "configured root") }
            return Result(root: nil, reason: "configured root does not exist: \(abs)")
        }

        // 3. The saved file is itself a root.
        if let savedContent, hasDocumentclass(savedContent) {
            return Result(root: saved, reason: "\\documentclass in the saved file")
        }

        // 4. Every root that reaches the saved file, ranked.
        var reaching: [(file: String, viaFls: Bool)] = []
        var seen = Set<String>()
        for candidate in fs.listTexFiles().map({ resolve("/", $0) }) where candidate != saved {
            guard seen.insert(candidate).inserted,
                  let content = fs.readFile(candidate), hasDocumentclass(content) else { continue }
            let viaFls = fs.flsInputs(candidate).contains(saved)
            if viaFls || includeClosure(candidate, fs).contains(where: { $0.includes.contains(saved) }) {
                reaching.append((candidate, viaFls))
            }
        }
        if let best = rank(reaching, saved: saved, preferred: options.preferredRoot.map { resolve("/", $0) }).first {
            let how = best.viaFls ? ".fls of" : "include graph from"
            let others = reaching.count > 1 ? " (\(reaching.count - 1) other root(s) also include it)" : ""
            return Result(root: best.file, reason: "\(how) \((best.file as NSString).lastPathComponent)\(others)")
        }

        return Result(root: nil, reason: "no root found (no magic comment, setting, \\documentclass, or including root)")
    }
}
