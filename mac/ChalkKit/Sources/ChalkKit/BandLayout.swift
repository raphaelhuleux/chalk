import Foundation
import CoreGraphics

/// The tab band's arithmetic as one pure function, so every window mode's
/// branch is testable without a window. Live-view reads stay in the
/// controller: this takes the measured divider and flags and returns numbers.
public enum BandLayout {
    /// The spec constants the band is built from, passed in because they live
    /// in the app target's `ChalkMetrics`, which is UIKit.
    public struct Metrics: Equatable, Sendable {
        public var tabStripHeight: CGFloat
        public var tabStripLeading: CGFloat
        public var tabRowDividerGap: CGFloat
        public var editorRestingPad: CGFloat

        public init(tabStripHeight: CGFloat, tabStripLeading: CGFloat,
                    tabRowDividerGap: CGFloat, editorRestingPad: CGFloat) {
            self.tabStripHeight = tabStripHeight
            self.tabStripLeading = tabStripLeading
            self.tabRowDividerGap = tabRowDividerGap
            self.editorRestingPad = editorRestingPad
        }
    }

    /// What one band-layout pass decided.
    public struct Result: Equatable, Sendable {
        public var bandHeight: CGFloat
        /// Where the tab names start, from the band's leading edge. The band
        /// itself never moves: it spans the window and the Library is cut out
        /// of its paint.
        public var chipLeadingInset: CGFloat
        /// Whether the UIKit band is the tab UI here. False on windowed Mac,
        /// where the tab row is the AppKit titlebar strip.
        public var bandOwnsTabRow: Bool
        /// The editor's explicit top clearance: 0 where the text runs
        /// full-bleed under the chrome, the system inset in the Mac no-glue
        /// fallback.
        public var editorTopClearance: CGFloat
        /// The text's resting top offset, pushed web-side. Nil in that same
        /// fallback, which keeps the stylesheet's own resting padding.
        public var editorChromeTopInset: CGFloat?
        /// The titlebar height to remember for the next full-screen episode;
        /// echoed back unchanged where this pass learned nothing.
        public var recordedBandHeight: CGFloat
    }

    /// A safe-area top under this is a transient mid-transition value, not a
    /// titlebar, so the last real reading is kept.
    public static let macTitlebarRealFloor: CGFloat = 20

    /// - Parameters:
    ///   - glueAvailable: the AppKit strip bundle loaded. Without it the
    ///     UIKit band is the tab UI and the editor clears it.
    ///   - fullscreen: full screen, where the UIKit band is the tab UI.
    ///   - safeAreaTop: the system titlebar on a windowed Mac.
    ///   - dividerX: the sidebar/editor divider in root points; 0 when no
    ///     Library is tiled.
    public static func resolve(
        glueAvailable: Bool, fullscreen: Bool, zen: Bool,
        safeAreaTop: CGFloat, lastRealBandHeight: CGFloat, dividerX: CGFloat,
        metrics: Metrics
    ) -> Result {
        // Recorded only from a windowed pass with the glue up, the one
        // state where `safeAreaTop` is the real system titlebar (without
        // the glue the band is folded into the safe area).
        let recorded = (glueAvailable && !fullscreen && safeAreaTop > macTitlebarRealFloor)
            ? safeAreaTop : lastRealBandHeight
        // Full screen has no useful safe area, so it reuses the cached
        // windowed height and the band stays identical across the swap.
        // Floored at the row's height: the chips are bottom-anchored, so a
        // shorter band clips their top above the window.
        let band = max(fullscreen ? lastRealBandHeight : safeAreaTop, metrics.tabStripHeight)
        guard glueAvailable else {
            return Result(bandHeight: band, chipLeadingInset: 0, bandOwnsTabRow: fullscreen,
                          editorTopClearance: safeAreaTop, editorChromeTopInset: nil,
                          recordedBandHeight: recorded)
        }
        // Overlay chrome: the editor runs full-bleed under the titlebar and
        // rests below web-side padding, so scrolled text reaches the top
        // edge. Windowed rests below the band, which is the titlebar when
        // that is taller than the row and the row's floor otherwise (a short
        // titlebar still hosts the row, and text must not rest under the
        // chips); `recorded` covers a transient safe area mid-transition.
        let restsBelow = fullscreen ? (zen ? 0 : band)
                                    : (zen ? safeAreaTop : max(band, recorded))
        return Result(
            bandHeight: band,
            // The row's `tabStripLeading` clears the traffic lights; past
            // the divider, swap it for the divider gap.
            chipLeadingInset: dividerX > 0
                ? dividerX + metrics.tabRowDividerGap - metrics.tabStripLeading : 0,
            bandOwnsTabRow: fullscreen, editorTopClearance: 0,
            editorChromeTopInset: restsBelow + metrics.editorRestingPad,
            recordedBandHeight: recorded)
    }
}
