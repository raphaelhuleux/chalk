import Foundation
import ChalkKit
import os

private let compileLog = Logger(subsystem: "com.huleux.chalk", category: "compile")

/// One window's compiles: which root a file typesets, the runs themselves
/// (off the main thread, coalesced per root), and SyncTeX lookups. The
/// planning and parsing rules live in ChalkKit (`LatexRoot`, `CompilePlanner`,
/// `CompileLog`, `SyncTeX`); this class only schedules and holds state.
final class CompileController {
    enum Phase: Equatable {
        case idle
        case running
        case finished(succeeded: Bool)
        /// Could not even start (missing tool, no root).
        case failed(String)
    }

    /// What the PDF panel shows for one root.
    struct State {
        var root: URL
        var phase: Phase = .idle
        var log = ""
        var issues: [CompileIssue] = []
        var finishedAt: Date?
    }

    /// Fired on the main queue whenever a root's state changes.
    var onStateChange: ((URL) -> Void)?
    /// This window's Library roots: they bound the search for a chapter's root.
    var libraryRootsProvider: () -> [URL] = { [] }

    private(set) var states: [URL: State] = [:]
    private let coalescer = CompileCoalescer()
    /// Saved file → the root it last compiled with, for `LatexRoot.Options.preferredRoot`.
    private var lastRoot: [String: String] = [:]
    /// Markdown files compiled this session: their saves compile from then on.
    private var compiledFiles = Set<String>()
    private var runners: [URL: CompileProcessRunner] = [:]
    private let queue = DispatchQueue(label: "com.huleux.chalk.compile", qos: .userInitiated, attributes: .concurrent)

    /// Bounds on the walk for including roots; a paper project is a handful of files.
    private static let walkMaxDepth = 8
    private static let walkMaxTexFiles = 200
    /// Without a Library root, roots are searched this many folders above the file.
    private static let looseFileWalkUp = 2

    // MARK: Tools

    /// Shared by every window: the login shell is asked once per launch.
    private static let loginShellPath: String? = ToolLocator.readLoginShellPath()

    /// Blocking on first use (the login shell). Call off the main thread.
    static func makeLocator() -> ToolLocator {
        let extra = Preferences.extraToolDirectory
        let path = ToolLocator.searchPath(loginShellPath: loginShellPath)
        return ToolLocator(searchPath: extra.isEmpty ? path : [extra] + path)
    }

    /// Mac App Store builds would run sandboxed, where launching TeX Live is not allowed.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    // MARK: Roots

    /// The file that typesets `file`: itself for Markdown, the resolved root for TeX.
    /// Blocking (walks the folder); call off the main thread.
    func resolveRoot(for file: URL) -> (root: URL?, reason: String) {
        guard CompileSource(fileExtension: file.pathExtension) == .latex else { return (file, "the file itself") }
        let saved = file.standardizedFileURL.path
        let dir = file.deletingLastPathComponent()
        let walkRoot = AssetResolution.workspaceRoot(for: dir, roots: libraryRootsProvider())
            ?? (0..<Self.looseFileWalkUp).reduce(dir) { url, _ in url.deletingLastPathComponent() }
        var reads: [String: String?] = [:]
        let readFile = { (path: String) -> String? in
            if let cached = reads[path] { return cached }
            let text = try? String(contentsOfFile: path, encoding: .utf8)
            reads[path] = text
            return text
        }
        let fs = LatexRoot.FileSystem(
            readFile: readFile,
            exists: { FileManager.default.fileExists(atPath: $0) },
            listTexFiles: { Self.listTexFiles(under: walkRoot) },
            // latexmk and pdflatex write the recorder file beside the root.
            flsInputs: { root in
                let fls = (root as NSString).deletingPathExtension + ".fls"
                return readFile(fls).map(LatexRoot.parseFlsInputs) ?? []
            }
        )
        let preferred = DispatchQueue.main.sync { lastRoot[saved] }
        let result = LatexRoot.find(saved: saved, fs: fs, options: .init(workspaceDir: walkRoot.path, preferredRoot: preferred))
        return (result.root.map { URL(fileURLWithPath: $0) }, result.reason)
    }

    private static func listTexFiles(under root: URL) -> [String] {
        var found: [String] = []
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in walker {
            if walker.level > walkMaxDepth { walker.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if ["node_modules", "build", "dist", "_build"].contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard url.pathExtension == "tex" else { continue }
            found.append(url.standardizedFileURL.path)
            if found.count >= walkMaxTexFiles { break }
        }
        return found
    }

    // MARK: Compile

    /// Whether a Cmd+S of `file` compiles: a .tex file always, Markdown once
    /// it was compiled this session or its PDF is on screen.
    func compilesOnSave(_ file: URL, pdfPanelShowing: Bool) -> Bool {
        guard Preferences.compileOnSave, let kind = CompileSource(fileExtension: file.pathExtension) else { return false }
        if kind == .latex { return true }
        return pdfPanelShowing || compiledFiles.contains(file.standardizedFileURL.path)
    }

    /// Compile `file` (through its root). `completion(root)` fires on the main
    /// queue once the root is known, before the run ends; nil when there is none.
    func compile(_ file: URL, completion: ((URL?) -> Void)? = nil) {
        guard !Self.isSandboxed else {
            completion?(nil)
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let (root, reason) = self.resolveRoot(for: file)
            DispatchQueue.main.async {
                guard let root else {
                    compileLog.info("no root for \(file.lastPathComponent, privacy: .private): \(reason, privacy: .public)")
                    let key = file.standardizedFileURL
                    self.states[key] = State(root: key, phase: .failed("No LaTeX root found: \(reason)."))
                    self.onStateChange?(key)
                    completion?(nil)
                    return
                }
                self.lastRoot[file.standardizedFileURL.path] = root.path
                if CompileSource(fileExtension: file.pathExtension) != .latex {
                    self.compiledFiles.insert(file.standardizedFileURL.path)
                }
                if self.coalescer.request(root.path) == .start { self.run(root) }
                completion?(root)
            }
        }
    }

    /// The root `file` compiled with last this session, if any.
    func knownRoot(for file: URL) -> URL? {
        if CompileSource(fileExtension: file.pathExtension) != .latex { return file.standardizedFileURL }
        return lastRoot[file.standardizedFileURL.path].map { URL(fileURLWithPath: $0) }
    }

    /// Resolve `file`'s root without compiling (the panel on a tab switch).
    func lookUpRoot(for file: URL, completion: @escaping (URL?) -> Void) {
        if let known = knownRoot(for: file) { return completion(known) }
        queue.async { [weak self] in
            let root = self?.resolveRoot(for: file).root
            DispatchQueue.main.async {
                if let root, let self { self.lastRoot[file.standardizedFileURL.path] = root.path }
                completion(root)
            }
        }
    }

    static func pdf(for root: URL) -> URL { root.deletingPathExtension().appendingPathExtension("pdf") }

    private func run(_ root: URL) {
        var state = states[root] ?? State(root: root)
        state.phase = .running
        states[root] = state
        onStateChange?(root)
        let settings = Preferences.compileSettings
        queue.async { [weak self] in
            guard let self else { return }
            let locator = Self.makeLocator()
            let source = (try? String(contentsOf: root, encoding: .utf8)) ?? ""
            let planned = CompilePlanner.job(for: root, source: source, settings: settings,
                                             available: { locator.locate($0) != nil })
            var outcome: CompileOutcome?
            var planError: String?
            switch planned {
            case let .success(job):
                let runner = CompileProcessRunner(locator: locator)
                DispatchQueue.main.sync { self.runners[root] = runner }
                outcome = runner.run(job)
            case let .failure(error):
                planError = error.description
            }
            DispatchQueue.main.async {
                self.runners[root] = nil
                var state = self.states[root] ?? State(root: root)
                if let outcome {
                    state.phase = .finished(succeeded: outcome.succeeded)
                    state.log = outcome.log
                    state.issues = outcome.issues
                } else {
                    state.phase = .failed(planError ?? "Could not compile.")
                    state.log = planError ?? ""
                    state.issues = []
                }
                state.finishedAt = Date()
                self.states[root] = state
                self.onStateChange?(root)
                if self.coalescer.finished(root.path) { self.run(root) }
            }
        }
    }

    /// Stop every run (window closing).
    func cancelAll() {
        runners.values.forEach { $0.cancel() }
    }

    // MARK: SyncTeX

    /// Source line to PDF box. `completion` on main; nil when synctex has no answer.
    func forwardSync(file: URL, line: Int, root: URL, completion: @escaping (SyncTeX.PDFLocation?) -> Void) {
        let pdf = Self.pdf(for: root)
        queue.async {
            let out = Self.runSynctex(SyncTeX.viewArguments(line: line, input: file.standardizedFileURL.path, pdf: pdf.path),
                                      in: root.deletingLastPathComponent())
            let hit = out.flatMap(SyncTeX.parseView)
            DispatchQueue.main.async { completion(hit) }
        }
    }

    /// PDF point (top-left origin, 1-based page) to source file and line.
    func reverseSync(pdf: URL, page: Int, x: Double, y: Double, completion: @escaping (SyncTeX.SourceLocation?) -> Void) {
        queue.async {
            let out = Self.runSynctex(SyncTeX.editArguments(page: page, x: x, y: y, pdf: pdf.path),
                                      in: pdf.deletingLastPathComponent())
            let hit = out.flatMap(SyncTeX.parseEdit)
            DispatchQueue.main.async { completion(hit) }
        }
    }

    private static func runSynctex(_ args: [String], in dir: URL) -> String? {
        guard let synctex = makeLocator().locate("synctex") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: synctex)
        process.arguments = args
        process.currentDirectoryURL = dir
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
