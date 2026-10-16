import Foundation

/// What the previous session's ending looked like, seen from this launch.
public enum LaunchVerdict: Equatable, Sendable {
    /// No marker at all: the first run, or the app's data was cleared.
    case firstLaunch
    /// Something ran the clean-shutdown path. Nothing to report.
    case clean
    /// The marker was still armed, so nothing ran it. `build` is the build
    /// that died, which may not be the one running now.
    case abnormal(build: String)
}

/// Did Chalk die last time? There is no crash reporter by design (it would
/// be a network connection). One marker holds the build string while a
/// foreground session is live and is cleared on every orderly exit; still
/// armed at the next launch means a crash.
///
/// Fail-open: ambiguous cases resolve to `.clean`, because false crash prompts
/// train testers to dismiss the real one. Accepted misses:
///
/// - `UserDefaults` flushes asynchronously. Do **not** add `synchronize()`:
///   deprecated, blocks the main thread, on every foreground.
/// - A force quit between the last `markForeground` and the flush reads as
///   clean. A counter of live windows would leak positive on any unbalanced
///   close and cry crash forever, so one marker it stays.
///
/// `RecoveryStore` residue corroborates but cannot trigger: a crash with no
/// dirty buffers leaves none.
public final class LaunchIntegrity {
    private let defaults: UserDefaults
    private let build: String
    private let key: String

    public init(defaults: UserDefaults = .standard,
                build: String,
                key: String = "chalk.launchMarker") {
        self.defaults = defaults
        self.build = build
        self.key = key
    }

    /// Read the previous session's verdict and clear the marker. Call once,
    /// from `applicationDidFinishLaunching`, before any window opens. Clearing (not
    /// arming) stops a windowless quit reading as a crash, and one crash being
    /// reported at every later launch.
    public func beginSession() -> LaunchVerdict {
        let verdict: LaunchVerdict
        switch defaults.string(forKey: key) {
        case .none: verdict = .firstLaunch
        case .some(let armed) where armed.isEmpty: verdict = .clean
        case .some(let armed): verdict = .abnormal(build: armed)
        }
        defaults.set("", forKey: key)
        return verdict
    }

    /// A window is on screen. Call from `applicationDidBecomeActive`.
    public func markForeground() {
        defaults.set(build, forKey: key)
    }

    /// An orderly exit. Call from `applicationWillTerminate`.
    public func markClean() {
        defaults.set("", forKey: key)
    }
}
