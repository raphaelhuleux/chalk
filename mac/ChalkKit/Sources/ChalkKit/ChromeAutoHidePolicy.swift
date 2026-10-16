import Foundation

/// Auto-hiding chrome: scroll down hides the tab row, scroll up reveals it,
/// and near the document top it is always shown. The host feeds scroll
/// offsets; hysteresis lives here so scroll jitter can't flap the chrome.
public struct ChromeAutoHidePolicy {
    public enum Chrome: Equatable {
        case shown
        case hidden
    }

    /// Cumulative same-direction travel (pt) before the chrome hides.
    public let hideThreshold: Double
    /// Cumulative upward travel (pt) before it comes back; smaller, so
    /// revealing feels eager.
    public let showThreshold: Double
    /// Within this many points of the top, the chrome is always shown.
    public let topRevealDistance: Double

    public private(set) var chrome: Chrome = .shown

    /// Previous sample, nil until the first observation seeds the baseline.
    private var lastOffset: Double?
    /// Signed same-direction travel; a direction flip restarts it.
    private var run: Double = 0

    public init(
        hideThreshold: Double = 24,
        showThreshold: Double = 12,
        topRevealDistance: Double = 8
    ) {
        self.hideThreshold = hideThreshold
        self.showThreshold = showThreshold
        self.topRevealDistance = topRevealDistance
    }

    /// Feed the editor's current scroll offset; returns the resulting state.
    @discardableResult
    public mutating func observe(offset: Double) -> Chrome {
        defer { lastOffset = offset }
        guard let last = lastOffset else { return chrome }
        if offset <= topRevealDistance {
            run = 0
            chrome = .shown
            return chrome
        }
        let delta = offset - last
        guard delta != 0 else { return chrome }
        if run == 0 || (delta > 0) != (run > 0) {
            run = delta
        } else {
            run += delta
        }
        if run >= hideThreshold {
            chrome = .hidden
        } else if run <= -showThreshold {
            chrome = .shown
        }
        return chrome
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
