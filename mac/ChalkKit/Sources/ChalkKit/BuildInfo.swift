import Foundation

/// What this binary is: the version and the commit.
///
/// The commit is stamped by `scripts/release-mac.sh` through a build setting,
/// so any field can be absent, empty, or a literal `$(CHALK_GIT_COMMIT)`. Each
/// still has to resolve to something readable in About and in a bug report.
public struct BuildInfo {
    public let appVersion: String
    public let build: String
    /// The short git SHA, or "unstamped", so a screenshot names the exact
    /// commit.
    public let commit: String

    public static let current = BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])

    /// - Parameter infoDictionary: `[String: Any]` in production; tests pass a
    ///   `[String: String]` literal, which converts implicitly.
    public init(infoDictionary: [String: Any]) {
        func read(_ key: String) -> String? {
            guard let raw = infoDictionary[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // An undeclared build setting arrives as its own `$(...)` literal.
            guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
            return trimmed
        }

        appVersion = read("CFBundleShortVersionString") ?? "?"
        build = read("CFBundleVersion") ?? "?"
        commit = read("CHALKGitCommit") ?? "unstamped"
    }

    /// Everything a bug report says about the machine it came from. Assembled
    /// here and nowhere else, so there is one place to check the claim that a
    /// report carries no file names, paths or text.
    public var reportEnvironment: BugReportEnvironment {
        BugReportEnvironment(
            appVersion: appVersion,
            build: build,
            commit: commit,
            systemVersion: Self.systemVersion,
            model: Self.model,
            locale: Locale.current.identifier)
    }

    private static var systemVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return "macOS \(number)"
    }

    /// The device class, never the computer's name: that is the user's own
    /// words and has no place in a report.
    private static var model: String {
        return "Mac"
    }
}
