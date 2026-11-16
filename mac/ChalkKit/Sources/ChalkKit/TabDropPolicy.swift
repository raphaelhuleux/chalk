import Foundation
import CoreGraphics

/// Where a tab dragged over a tab group's editor lands. Over another group, VS Code's editor drop
/// target (editorDropTarget.ts): within 10% of an edge the drop splits, toward the side of the
/// outer thirds; deeper in, it moves the tab into the group. Chalk has no up/down split, so VS
/// Code's top and bottom bands of the middle third land in the group too. Over the tab's own
/// group, where VS Code's center shows nothing, each half splits toward its side, so the whole
/// group shows where the tab will land.
public enum TabDropPolicy {
    public enum Zone: Equatable, Sendable {
        /// Move the tab into this group.
        case center
        /// Split: a new group beside this one, on that side, holding the tab.
        case leading, trailing
    }

    /// Share of the group's width and height, from each edge, inside which a drop splits.
    public static let edgeFactor: CGFloat = 0.1

    /// The zone under `point` (group coordinates, origin at a corner) in a group of `size`, or
    /// nil for no drop: outside the group, or over its own group when that group cannot split
    /// (its only tab would leave it empty, or another group would not fit). `canSplit` false
    /// turns a split over another group into a center drop.
    public static func zone(at point: CGPoint, in size: CGSize, isSourceGroup: Bool,
                            sourceTabCount: Int, canSplit: Bool) -> Zone? {
        let w = size.width, h = size.height
        guard w > 0, h > 0, point.x >= 0, point.x <= w, point.y >= 0, point.y <= h else { return nil }
        if isSourceGroup {
            guard sourceTabCount > 1, canSplit else { return nil }
            return point.x < w / 2 ? .leading : .trailing
        }
        let edgeX = w * edgeFactor, edgeY = h * edgeFactor
        let inCenter = point.x > edgeX && point.x < w - edgeX && point.y > edgeY && point.y < h - edgeY
        var zone: Zone
        if inCenter {
            zone = .center
        } else if point.x < w / 3 {
            zone = .leading
        } else if point.x > w * 2 / 3 {
            zone = .trailing
        } else {
            zone = .center
        }
        if zone != .center && !canSplit { zone = .center }
        return zone
    }

    /// The drop indicator's frame for `zone` over a group's `bounds`: the half the new group
    /// would take, or the whole group.
    public static func overlayRect(for zone: Zone, in bounds: CGRect) -> CGRect {
        let half = (bounds.width / 2).rounded()
        switch zone {
        case .center:
            return bounds
        case .leading:
            return CGRect(x: bounds.minX, y: bounds.minY, width: half, height: bounds.height)
        case .trailing:
            return CGRect(x: bounds.maxX - half, y: bounds.minY, width: half, height: bounds.height)
        }
    }
}
