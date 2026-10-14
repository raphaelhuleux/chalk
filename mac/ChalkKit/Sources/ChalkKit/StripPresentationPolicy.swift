import Foundation
// Explicit: this file is also compiled into the AppKit glue (mac/project.yml).
import CoreGraphics

/// The titlebar strip's resting appearance, as a value.
public struct StripPresentation: Equatable, Sendable {
    /// `isHidden` for the strip and its background paint. AppKit hit-tests
    /// alpha-0 views, so anything invisible must also be hidden.
    public let isHidden: Bool
    /// `alphaValue` for both.
    public let alpha: CGFloat

    public init(isHidden: Bool, alpha: CGFloat) {
        self.isHidden = isHidden
        self.alpha = alpha
    }
}

/// How the strip's two independent inputs combine: chrome visibility (hidden
/// in full screen) and the chip fade (auto-hide, zen).
///
/// Neither input may write `isHidden` alone: an un-fade that did so revealed
/// a second tab row in full screen (bandAndStripNeverBothCarryTheTabs).
public enum StripPresentationPolicy {
    /// Hidden when the chrome is hidden **or** the chips are faded; the fade
    /// is the only thing that changes alpha.
    public static func resolve(chromeVisible: Bool, chipsFaded: Bool) -> StripPresentation {
        StripPresentation(isHidden: !chromeVisible || chipsFaded, alpha: chipsFaded ? 0 : 1)
    }
}
