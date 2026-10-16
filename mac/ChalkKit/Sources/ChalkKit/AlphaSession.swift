import Foundation

/// What the app knows about this run: how the last session ended, and
/// whether to ask about crashes.
///
/// One object so the crash prompt fires once, not once per window. `defaults`
/// is injected for tests.
public final class AlphaSession {
    private enum Key {
        static let declines = "chalk.crashPromptDeclines"
        static let promptEnabled = "chalk.crashPromptEnabled"
        static let launchMarker = "chalk.launchMarker"
    }

    public static let shared = AlphaSession()

    public let build: BuildInfo
    /// Read once, at construction: `beginSession` clears the marker, so a
    /// second read would report a clean exit.
    public let verdict: LaunchVerdict

    private let defaults: UserDefaults
    private let integrity: LaunchIntegrity

    public init(build: BuildInfo = .current,
         defaults: UserDefaults = .standard) {
        self.build = build
        self.defaults = defaults
        self.integrity = LaunchIntegrity(defaults: defaults, build: build.build,
                                         key: Key.launchMarker)
        self.verdict = integrity.beginSession()
    }

    // MARK: - Lifecycle

    /// A window is on screen. From `applicationDidBecomeActive`.
    public func markForeground() { integrity.markForeground() }

    /// An orderly exit. From `applicationWillTerminate`.
    public func markClean() { integrity.markClean() }

    // MARK: - The crash prompt

    /// The Settings switch. The app never sets this back to true.
    public var isCrashPromptEnabled: Bool {
        get {
            guard defaults.object(forKey: Key.promptEnabled) != nil else { return true }
            return defaults.bool(forKey: Key.promptEnabled)
        }
        set { defaults.set(newValue, forKey: Key.promptEnabled) }
    }

    public var shouldPromptAboutCrash: Bool {
        CrashPromptPolicy.shouldPrompt(
            verdict: verdict,
            declines: defaults.integer(forKey: Key.declines),
            userOptedOut: !isCrashPromptEnabled)
    }

    /// One window per launch gets to ask: every window activates at launch and
    /// would otherwise show its own banner. In memory, and it leaves the
    /// decline count alone: that moves only when the user answers.
    private var crashPromptClaimed = false

    public func claimCrashPrompt() -> Bool {
        guard shouldPromptAboutCrash, !crashPromptClaimed else { return false }
        crashPromptClaimed = true
        return true
    }

    public func recordCrashPromptOutcome(_ outcome: CrashPromptOutcome) {
        defaults.set(
            CrashPromptPolicy.declines(after: outcome,
                                       from: defaults.integer(forKey: Key.declines)),
            forKey: Key.declines)
    }
}
