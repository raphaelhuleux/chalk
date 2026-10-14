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

// ---------------------------------------------------------------------------
//  Chrome ownership. The tab row is carried by the UIKit band or the AppKit
//  strip depending on state, and auto-hide must be re-applied to BOTH on every
//  ownership change: `isHidden` preserves a slide-out transform, so a band
//  hidden by scroll and then handed off came back offscreen on the next
//  handover. A non-owner is always reset to shown.
// ---------------------------------------------------------------------------

/// Which chrome carries the tab row for a given shell state.
public enum TabChromeOwner: Equatable {
    /// The app's own UIKit header band: full screen, and the no-glue
    /// fallback where there is no titlebar strip to own it.
    case uiKitBand
    /// The AppKit strip in the window's titlebar (windowed Mac, glue loaded).
    case appKitStrip
    /// Zen: no tab row is shown at all.
    case none
}

/// How the auto-hide state must be written to the chrome, for every chrome —
/// not only the one that currently owns the tabs.
public struct ChromeAutoHideApplication: Equatable {
    /// The UIKit band's slide-out transform and alpha.
    public let bandHidden: Bool
    /// The AppKit strip's fade.
    public let stripFaded: Bool

    public init(bandHidden: Bool, stripFaded: Bool) {
        self.bandHidden = bandHidden
        self.stripFaded = stripFaded
    }
}

public enum TabChromeOwnership {
    /// Zen outranks everything; then the band owns the tabs whenever there is
    /// no titlebar strip (full screen, or no glue).
    public static func owner(
        isMacFullScreen: Bool,
        isZen: Bool,
        glueAvailable: Bool
    ) -> TabChromeOwner {
        if isZen { return .none }
        if !glueAvailable || isMacFullScreen { return .uiKitBand }
        return .appKitStrip
    }

    /// The hidden state to write to BOTH chromes. Only the owner may be left
    /// hidden. In zen the band is never slid out and the strip stays faded,
    /// since the fade is zen's resting titlebar.
    public static func autoHideApplication(
        owner: TabChromeOwner,
        autoHidden: Bool
    ) -> ChromeAutoHideApplication {
        ChromeAutoHideApplication(
            bandHidden: owner == .uiKitBand && autoHidden,
            stripFaded: (owner == .appKitStrip && autoHidden) || owner == .none)
    }
}
