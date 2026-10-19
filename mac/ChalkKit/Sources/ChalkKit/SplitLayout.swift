import Foundation
import CoreGraphics

/// Where a two-pane editor puts its seam. Pure arithmetic, so the clamp is testable without a
/// window and the chrome invariants can state the same rule.
public enum SplitLayout {
    /// The leading pane's width in a column `columnWidth` wide. Each pane keeps `minimumPane`; a
    /// column too narrow for two minimum panes splits in equal halves. Whole points, so neither
    /// web view straddles a pixel.
    public static func leadingWidth(columnWidth: CGFloat, fraction: CGFloat,
                                    minimumPane: CGFloat) -> CGFloat {
        guard columnWidth > 0 else { return 0 }
        guard columnWidth >= 2 * minimumPane else { return (columnWidth / 2).rounded(.down) }
        let proposed = (columnWidth * clampedFraction(fraction)).rounded()
        return min(columnWidth - minimumPane, max(minimumPane, proposed))
    }

    /// A stored fraction from an older build or a hand-edited default can be anything; NaN
    /// would poison every frame.
    public static func clampedFraction(_ fraction: CGFloat) -> CGFloat {
        guard fraction.isFinite else { return 0.5 }
        return min(0.9, max(0.1, fraction))
    }
}
