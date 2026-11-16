import Foundation

/// Auto-hiding chrome: scroll down hides the tab row, a deliberate scroll back up reveals it,
/// and near the document top it is always shown. The host feeds timed scroll offsets;
/// hysteresis lives here so scroll jitter and reading drift can't flap the chrome.
///
/// Revealing weighs how far AND how fast the reader scrolls up: a quick flick
/// (`flickDistance` within `flickWindow`) or a long climb (`revealDistance`) brings the
/// tabs back; the slow upward drift of re-reading a line does neither. A pause of
/// `pauseReset` ends a gesture, so separate small scrolls never add up.
public struct ChromeAutoHidePolicy {
    public enum Chrome: Equatable {
        case shown
        case hidden
    }

    /// Cumulative same-direction travel (pt) before the chrome hides.
    public let hideThreshold: Double
    /// Upward travel (pt) inside `flickWindow` that reveals: a quick reach for the tabs.
    public let flickDistance: Double
    /// Seconds over which `flickDistance` is measured.
    public let flickWindow: Double
    /// Upward travel (pt) in one gesture that reveals at any speed.
    public let revealDistance: Double
    /// A gap between samples longer than this (s) starts a new gesture.
    public let pauseReset: Double
    /// Within this many points of the top, the chrome is always shown.
    public let topRevealDistance: Double

    public private(set) var chrome: Chrome = .shown

    /// Previous sample, nil until the first observation seeds the baseline.
    private var last: (offset: Double, time: Double)?
    /// Signed same-direction travel in this gesture; a direction flip or a pause restarts it.
    private var run: Double = 0
    /// The run's recent moves, for the travel inside `flickWindow`.
    private var recent: [(time: Double, delta: Double)] = []

    public init(
        hideThreshold: Double = 24,
        flickDistance: Double = 100,
        flickWindow: Double = 0.25,
        revealDistance: Double = 300,
        pauseReset: Double = 0.4,
        topRevealDistance: Double = 8
    ) {
        self.hideThreshold = hideThreshold
        self.flickDistance = flickDistance
        self.flickWindow = flickWindow
        self.revealDistance = revealDistance
        self.pauseReset = pauseReset
        self.topRevealDistance = topRevealDistance
    }

    /// Feed the editor's scroll offset at `time` (seconds, any monotonic clock); returns the
    /// resulting state. `canHide` is false for a move the reader didn't scroll (a jump to a
    /// line, a reflow): it may reveal the chrome, never hide it, because nothing would then
    /// bring the tabs back until the next upward scroll.
    @discardableResult
    public mutating func observe(offset: Double, at time: Double, canHide: Bool = true) -> Chrome {
        defer { last = (offset, time) }
        guard let last else { return chrome }
        if offset <= topRevealDistance {
            restart()
            chrome = .shown
            return chrome
        }
        let delta = offset - last.offset
        guard delta != 0 else { return chrome }
        guard canHide || delta < 0 else {
            restart()
            return chrome
        }
        if run == 0 || (delta > 0) != (run > 0) || time - last.time > pauseReset {
            restart()
        }
        run += delta
        recent.append((time, delta))
        recent.removeAll { time - $0.time > flickWindow }
        if run >= hideThreshold {
            chrome = .hidden
        } else if run < 0 {
            let quick = -recent.reduce(0) { $0 + $1.delta }
            if quick >= flickDistance || -run >= revealDistance { chrome = .shown }
        }
        return chrome
    }

    private mutating func restart() {
        run = 0
        recent.removeAll()
    }
}

/// What the shell should do with the chrome right now, once the scroll
/// policy's answer is weighed against everything that outranks it.
public enum ChromeAutoHideDecision: Equatable {
    /// Zen owns visibility; auto-hide must keep its hands off.
    case unmanaged
    case shown
    case hidden
}

/// Composes the scroll policy with the states that outrank it. Stateless, so
/// the shell can call it on any input change without disturbing the policy's
/// accumulated scroll run.
public enum ChromeAutoHideGate {
    public static func decide(
        enabled: Bool,
        isZen: Bool,
        pointerInTopBand: Bool,
        scroll: ChromeAutoHidePolicy.Chrome
    ) -> ChromeAutoHideDecision {
        if isZen { return .unmanaged }
        guard enabled else { return .shown }
        if pointerInTopBand { return .shown }
        return scroll == .hidden ? .hidden : .shown
    }
}
