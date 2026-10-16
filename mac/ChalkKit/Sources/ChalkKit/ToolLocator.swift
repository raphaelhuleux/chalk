import Foundation

/// Finds the compile tools (latexmk, pdflatex, pandoc, quarto, synctex…).
///
/// An app launched from the Dock or Finder gets launchd's minimal PATH, not
/// the user's shell PATH, so `/Library/TeX/texbin` or a conda `pandoc` are
/// invisible to a plain `Process` lookup. The search path is the well-known
/// install folders plus whatever the login shell reports.
public struct ToolLocator {
    /// Where MacTeX, Homebrew, Quarto's installer and the system put binaries.
    public static let standardDirectories = [
        "/Library/TeX/texbin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/Applications/quarto/bin",
        "/usr/bin",
        "/bin",
    ]

    public let searchPath: [String]
    private let isExecutable: (String) -> Bool

    public init(searchPath: [String], isExecutable: @escaping (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) {
        self.searchPath = searchPath
        self.isExecutable = isExecutable
    }

    /// Standard folders first, then the login shell's entries, deduplicated
    /// in order.
    public static func searchPath(loginShellPath: String?) -> [String] {
        var seen = Set<String>()
        let shell = (loginShellPath ?? "").split(separator: ":").map(String.init)
        return (standardDirectories + shell).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Absolute path of `name`: `override` when it is executable (a path
    /// typed into Settings), else the first hit on the search path.
    public func locate(_ name: String, override: String? = nil) -> String? {
        if let override, !override.isEmpty {
            return isExecutable(override) ? override : nil
        }
        for dir in searchPath {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// The PATH a compile runs with, so latexmk finds pdflatex and biber
    /// the same way.
    public var environmentPath: String { searchPath.joined(separator: ":") }

    /// `$PATH` as the user's login shell sets it, or nil when the shell does
    /// not answer within `timeout`. Blocking: call once, off the main thread.
    public static func readLoginShellPath(timeout: TimeInterval = 3) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -l reads the login profile (.zprofile, .bash_profile), -i the rc
        // file where conda and nvm put their PATH edits. The markers fence off
        // anything the profile prints; the braces matter, since `$PATH__CHALK…`
        // is one (empty) variable name.
        process.arguments = ["-l", "-i", "-c", "echo __CHALK_PATH__${PATH}__CHALK_PATH__"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let start = text.range(of: "__CHALK_PATH__"),
              let end = text.range(of: "__CHALK_PATH__", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }
}
