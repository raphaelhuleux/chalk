import Foundation
import CoreGraphics

/// How the editor column is shared between side-by-side tab groups: one width fraction per
/// group, leading to trailing. Pure arithmetic, so the floor and the seam rules are testable
/// without a window and the chrome invariants can state the same rules.
public struct EditorGroupsLayout: Equatable, Sendable {
    /// One share per group, summing to 1.
    public private(set) var fractions: [CGFloat]

    public static let single = EditorGroupsLayout(fractions: [1])

    /// Any input is accepted: a stored layout from an older build or a hand-edited record can
    /// hold anything, and NaN would poison every frame. Bad shares become the mean of the good
    /// ones; an empty list is one group.
    public init(fractions: [CGFloat]) {
        guard !fractions.isEmpty else {
            self.fractions = [1]
            return
        }
        let good = fractions.filter { $0.isFinite && $0 > 0 }
        let fallback = good.isEmpty ? 1 : good.reduce(0, +) / CGFloat(good.count)
        let cleaned = fractions.map { $0.isFinite && $0 > 0 ? $0 : fallback }
        let total = cleaned.reduce(0, +)
        self.fractions = cleaned.map { $0 / total }
    }

    /// Equal shares for `count` groups.
    public static func even(_ count: Int) -> EditorGroupsLayout {
        EditorGroupsLayout(fractions: Array(repeating: 1, count: max(1, count)))
    }

    public var count: Int { fractions.count }

    /// This layout when it has `count` groups, else equal shares: a stored or dragged layout
    /// never sizes a different set of groups.
    public func fitted(toCount count: Int) -> EditorGroupsLayout {
        self.count == count ? self : .even(count)
    }

    /// Each group's width in a column `columnWidth` wide, leading to trailing. Each group keeps
    /// `minimum`; a column too narrow for that splits evenly. Every group but the last gets whole
    /// points (the last takes the remainder), so no seam straddles a pixel.
    public func widths(columnWidth: CGFloat, minimum: CGFloat) -> [CGFloat] {
        let n = fractions.count
        guard columnWidth > 0 else { return Array(repeating: 0, count: n) }
        var raw: [CGFloat]
        if columnWidth < CGFloat(n) * minimum {
            raw = Array(repeating: columnWidth / CGFloat(n), count: n)
        } else {
            raw = fractions.map { $0 * columnWidth }
            // Pin the groups under the floor to it and share what is left among the rest in
            // proportion, until none is under. Each pass pins at least one more group.
            var pinned = Array(repeating: false, count: n)
            while raw.indices.contains(where: { !pinned[$0] && raw[$0] < minimum }) {
                for i in raw.indices where !pinned[i] && raw[i] < minimum {
                    pinned[i] = true
                    raw[i] = minimum
                }
                let free = raw.indices.filter { !pinned[$0] }
                let left = columnWidth - CGFloat(n - free.count) * minimum
                let share = free.reduce(CGFloat(0)) { $0 + fractions[$1] }
                for i in free { raw[i] = share > 0 ? left * fractions[i] / share : left / CGFloat(free.count) }
            }
        }
        // Flooring the first n-1 only ever grows the last, so no group drops under the floor. The
        // nudge keeps share arithmetic noise (399.99999…) from losing a whole point.
        var widths = raw.dropLast().map { ($0 + 1e-6).rounded(.down) }
        widths.append(columnWidth - widths.reduce(0, +))
        return widths
    }

    /// Whether one more group fits beside these at `minimum` each.
    public func canInsert(columnWidth: CGFloat, minimum: CGFloat) -> Bool {
        CGFloat(count + 1) * minimum <= columnWidth
    }

    /// A new group at `index` (0...count), taking half of group `target`'s share: splitting a
    /// group halves it and leaves its neighbours alone.
    public func inserting(at index: Int, splitting target: Int) -> EditorGroupsLayout {
        guard fractions.indices.contains(target) else { return .even(count + 1) }
        var shares = fractions
        let half = shares[target] / 2
        shares[target] = half
        shares.insert(half, at: min(max(0, index), shares.count))
        return EditorGroupsLayout(fractions: shares)
    }

    /// Group `index` closed: its share goes to the leading neighbour (the trailing one for the
    /// first group), so the rest of the row does not move.
    public func removing(at index: Int) -> EditorGroupsLayout {
        guard count > 1, fractions.indices.contains(index) else { return self }
        var shares = fractions
        let freed = shares.remove(at: index)
        shares[index == 0 ? 0 : index - 1] += freed
        return EditorGroupsLayout(fractions: shares)
    }

    /// A seam drag: seam `seam` sits between groups `seam` and `seam + 1` and moved `dx` from
    /// where it was when `startWidths` were laid out. Only those two groups change, and each
    /// keeps `minimum` when the pair is wide enough for it.
    public static func resized(startWidths: [CGFloat], seam: Int, by dx: CGFloat,
                               minimum: CGFloat) -> EditorGroupsLayout {
        guard seam >= 0, seam + 1 < startWidths.count, dx.isFinite else {
            return EditorGroupsLayout(fractions: startWidths)
        }
        var widths = startWidths
        let pair = widths[seam] + widths[seam + 1]
        let floor = min(minimum, pair / 2)
        let leading = min(pair - floor, max(floor, widths[seam] + dx))
        widths[seam] = leading
        widths[seam + 1] = pair - leading
        return EditorGroupsLayout(fractions: widths)
    }
}
