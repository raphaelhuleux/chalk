import CoreGraphics
import Foundation

/// How a fixed-width tab row distributes its width across tabs, and when it
/// gives up and sends tabs to the overflow menu.
///
/// The rule: a chip on screen is readable. Chips shrink toward
/// `minimumTabWidth`, then the rest go to the chevron menu (Auto Layout
/// squeezed them to zero instead:
/// docs/issues/2026-08-18-mac-tabs-vanish-when-the-library-is-open.md).
///
/// Used by the AppKit `ChalkTabStrip`; lives here, compiled into the glue,
/// because no test target can reach the glue.
public enum TabStripFit {
    /// The narrowest a tab may be squeezed before the row stops squeezing and
    /// starts hiding.
    ///
    /// 16pt of item padding leaves 56pt of label: 7-8 characters of 12pt mono
    /// plus the ellipsis, enough to tell two open files apart.
    public static let minimumTabWidth: CGFloat = 72

    public struct Plan: Equatable {
        /// Planned width per tab, in row order. Hidden tabs carry their
        /// floor width rather than 0.
        public let widths: [CGFloat]
        /// Chips that did not fit and now live in the chevron menu.
        public let hidden: Set<Int>
        /// Whether the chevron is needed: any tab hidden, or any label
        /// truncated (the menu is also how you read a name that got cut).
        public let showsOverflow: Bool

        public var visibleCount: Int { widths.count - hidden.count }

        public func isVisible(_ index: Int) -> Bool { !hidden.contains(index) }
    }

    /// - Parameters:
    ///   - naturalWidths: each chip's width with its label untruncated, in
    ///     strip order.
    ///   - activeIndex: the selected tab, squeezed last and never hidden.
    ///     Out of range means "no active tab" (the tab model and the active
    ///     flag can be momentarily skewed).
    ///   - available: the width the chips may occupy, i.e. the strip minus the
    ///     new-tab button and the chevron.
    ///   - spacing: the gap BETWEEN two neighbouring tabs; ignoring it hands
    ///     out more width than the row has. Defaults to 0.
    public static func plan(
        naturalWidths: [CGFloat],
        activeIndex: Int?,
        available: CGFloat,
        spacing: CGFloat = 0
    ) -> Plan {
        guard !naturalWidths.isEmpty else {
            return Plan(widths: [], hidden: [], showsOverflow: false)
        }
        let active = activeIndex.flatMap { naturalWidths.indices.contains($0) ? $0 : nil }
        let floors = naturalWidths.map { min($0, minimumTabWidth) }

        // 1. Hide from the trailing end until the survivors fit at their
        //    floors. The active tab is never a candidate, and one chip always
        //    survives: an unmeasured strip reports zero width.
        var hidden: Set<Int> = []
        // n tabs carry n-1 gaps; each hidden tab takes one with it.
        var floorTotal = floors.reduce(0, +)
            + spacing * CGFloat(max(0, naturalWidths.count - 1))
        var candidates = naturalWidths.indices.reversed().filter { $0 != active }
        while floorTotal > available, hidden.count < naturalWidths.count - 1,
              let next = candidates.first {
            candidates.removeFirst()
            hidden.insert(next)
            floorTotal -= floors[next] + spacing
        }

        let visible = naturalWidths.indices.filter { !hidden.contains($0) }

        // 2. Inactive chips give up slack (natural minus floor) in
        //    proportion; the active chip yields only once they are all at
        //    their floors.
        var widths = naturalWidths
        var shortfall = visible.reduce(0) { $0 + naturalWidths[$1] }
            + spacing * CGFloat(max(0, visible.count - 1)) - available
        if shortfall > 0 {
            let yielding = visible.filter { $0 != active }
            let slack = yielding.reduce(CGFloat(0)) { $0 + naturalWidths[$1] - floors[$1] }
            if slack > 0 {
                let taken = min(shortfall, slack)
                for index in yielding {
                    widths[index] = naturalWidths[index]
                        - (naturalWidths[index] - floors[index]) * (taken / slack)
                }
                shortfall -= taken
            }
            if shortfall > 0, let active, !hidden.contains(active) {
                widths[active] = max(floors[active], naturalWidths[active] - shortfall)
            }
        }
        for index in hidden { widths[index] = floors[index] }

        let squeezed = visible.contains { widths[$0] < naturalWidths[$0] - 0.5 }
        return Plan(
            widths: widths, hidden: hidden, showsOverflow: !hidden.isEmpty || squeezed)
    }
}
