import Foundation

/// One compile at a time per key (the root file), and no save lost: a request
/// while that key compiles marks it dirty, and `finished` says to run once
/// more, however many requests arrived meanwhile. Same rule as the VS Code
/// extension's `BuildQueue`. Not thread-safe: call from one queue (main).
public final class CompileCoalescer {
    public enum Admission: Equatable { case start, queued }

    private var running = Set<String>()
    private var dirty = Set<String>()

    public init() {}

    public func request(_ key: String) -> Admission {
        if running.contains(key) {
            dirty.insert(key)
            return .queued
        }
        running.insert(key)
        return .start
    }

    /// Call when a run of `key` ends. True: run it again now (the key stays
    /// running). False: the key is idle.
    public func finished(_ key: String) -> Bool {
        if dirty.remove(key) != nil { return true }
        running.remove(key)
        return false
    }

    public func isRunning(_ key: String) -> Bool { running.contains(key) }
}

/// The result of running a `CompileJob`.
public struct CompileOutcome: Sendable {
    public var succeeded: Bool
    public var cancelled: Bool
    /// Notes, commands and their combined output, in order.
    public var log: String
    public var issues: [CompileIssue]
    /// The PDF when this run wrote it (a failed run can still produce one).
    public var pdf: URL?
}

/// Runs a `CompileJob`'s processes. `run` blocks: call it off the main
/// thread. `cancel` may come from any thread.
public final class CompileProcessRunner: @unchecked Sendable {
    private let locator: ToolLocator
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var current: Process?
    private var cancelled = false

    public init(locator: ToolLocator, timeout: TimeInterval = 600) {
        self.locator = locator
        self.timeout = timeout
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let process = current
        lock.unlock()
        process?.terminate()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func run(_ job: CompileJob) -> CompileOutcome {
        lock.lock()
        cancelled = false
        lock.unlock()
        let start = Date()
        var log = job.notes.map { "[chalk] \($0)\n" }.joined()
        var ok = true
        if let staged = job.staged {
            let url = job.workingDirectory.appendingPathComponent(staged.fileName)
            do {
                try staged.contents.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                log += "[chalk] could not write \(staged.fileName): \(error.localizedDescription)\n"
                return CompileOutcome(succeeded: false, cancelled: false, log: log, issues: [], pdf: nil)
            }
        }
        defer {
            if let staged = job.staged {
                let fm = FileManager.default
                let base = job.workingDirectory.appendingPathComponent(staged.fileName)
                try? fm.removeItem(at: base)
                // Quarto's supporting folder, left behind when a render fails.
                try? fm.removeItem(at: job.workingDirectory
                    .appendingPathComponent(base.deletingPathExtension().lastPathComponent + "_files"))
            }
        }

        func step(_ tool: String, _ args: [String]) -> (code: Int32, output: String) {
            let (code, output) = execute(tool, args, in: job.workingDirectory)
            log += "[chalk] $ \(tool) \(args.joined(separator: " "))\n" + output
            if code != 0 { log += "[chalk] \(tool) exited with \(code)\n" }
            return (code, output)
        }

        switch job.plan {
        case let .steps(steps):
            for s in steps where ok && !isCancelled {
                ok = step(s.tool, s.arguments).code == 0
            }
        case let .latexPasses(program, file):
            let args = LatexPasses.programArguments(file: file)
            var pass = step(program.rawValue, args)
            ok = pass.code == 0
            let base = job.workingDirectory.appendingPathComponent((file as NSString).deletingPathExtension)
            let aux = try? String(contentsOf: base.appendingPathExtension("aux"), encoding: .utf8)
            let bcf = FileManager.default.fileExists(atPath: base.appendingPathExtension("bcf").path)
            if ok, !isCancelled, let bib = LatexPasses.bibliographyTool(aux: aux, bcfExists: bcf) {
                // A bibliography error is reported but the passes go on, as latexmk does.
                _ = step(bib, [base.lastPathComponent])
                pass = step(program.rawValue, args)
                ok = pass.code == 0
            }
            var reruns = 0
            while ok, !isCancelled, reruns < LatexPasses.maxReruns, LatexPasses.needsRerun(output: pass.output) {
                pass = step(program.rawValue, args)
                ok = pass.code == 0
                reruns += 1
            }
        }

        let wasCancelled = isCancelled
        if wasCancelled { log += "[chalk] cancelled\n" }
        let modified = (try? job.pdf.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let fresh = modified.map { $0 >= start.addingTimeInterval(-1) } ?? false
        return CompileOutcome(
            succeeded: ok && !wasCancelled,
            cancelled: wasCancelled,
            log: log,
            issues: CompileLog.issues(in: log),
            pdf: fresh ? job.pdf : nil
        )
    }

    /// One process, output (stdout and stderr together) collected as it
    /// arrives so a chatty tool never fills the pipe and stalls.
    private func execute(_ tool: String, _ args: [String], in dir: URL) -> (Int32, String) {
        guard let path = locator.locate(tool) else { return (127, "[chalk] \(tool) not found on \(locator.environmentPath)\n") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = locator.environmentPath
        // Keeps TeX from hard-wrapping log lines at 79 columns.
        env["max_print_line"] = "10000"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { buffer.append($0.availableData) }

        lock.lock()
        if cancelled {
            lock.unlock()
            return (-1, "")
        }
        current = process
        lock.unlock()
        defer {
            lock.lock()
            current = nil
            lock.unlock()
        }

        do { try process.run() } catch { return (-1, "[chalk] could not start \(path): \(error.localizedDescription)\n") }
        let timer = DispatchWorkItem { [weak process] in process?.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        process.waitUntilExit()
        timer.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        // After a kill, a grandchild (latexmk's pdflatex) can keep the pipe
        // open, and reading to its end would block; take what has arrived.
        if process.terminationReason == .exit {
            buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
        }
        var output = buffer.text
        if process.terminationReason == .uncaughtSignal, !isCancelled {
            output += "[chalk] \(tool) stopped after \(Int(timeout / 60)) min\n"
        }
        return (process.terminationStatus, output)
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
