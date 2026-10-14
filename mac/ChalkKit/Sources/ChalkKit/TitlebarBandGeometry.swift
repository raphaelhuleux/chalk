import Foundation

/// Where the Mac titlebar's strip background paints.
///
/// Pure geometry, here rather than in the glue, because no test target can
/// reach `ChalkAppKitGlue`.
///
/// The band spans the whole titlebar. AppKit draws the titlebar ABOVE the
/// UIKit content, so running it "under" the Library cannot be done by
/// z-order: the band is filled MINUS the panel. The hole is a plain rectangle
/// because the panel is flat and flush; if the panel ever rounds or insets,
/// the hole must follow it or a corner notch appears.
public enum TitlebarBandGeometry {
    /// What to fill: `band`, minus `libraryHole` if there is one.
    public struct Paint: Equatable {
        /// The full strip, in the background view's coordinates (AppKit, y-up).
        public let band: CGRect
        /// The Library panel's rectangle, to be subtracted. Nil when the
        /// Library is hidden.
        ///
        /// It extends BELOW `band` so its bottom edge never lands inside the
        /// strip. The caller must clip to `band` when filling: under even-odd
        /// the part outside the band would fill.
        public let libraryHole: CGRect?
        /// The outline panel's rectangle on the trailing edge, subtracted and
        /// extended below the band like `libraryHole`. Nil when hidden.
        public let outlineHole: CGRect?

        public init(band: CGRect, libraryHole: CGRect?, outlineHole: CGRect? = nil) {
            self.band = band
            self.libraryHole = libraryHole
            self.outlineHole = outlineHole
        }

        /// Whether `point` ends up painted by the caller's clipped even-odd
        /// fill, testable without a drawing context.
        public func paints(_ point: CGPoint) -> Bool {
            guard band.contains(point) else { return false }
            if let hole = libraryHole, hole.contains(point) { return false }
            if let hole = outlineHole, hole.contains(point) { return false }
            return true
        }
    }

    /// - Parameters:
    ///   - bounds: the titlebar's bounds.
    ///   - chipBaseline: distance from the titlebar's bottom to the tab row's
    ///     bottom edge; the sliver below stays unpainted.
    ///   - libraryWidth: the sidebar/editor divider's x. 0 when the Library is
    ///     hidden, and the band is then one uninterrupted strip.
    ///   - outlineWidth: the outline panel's width, measured in from the
    ///     window's trailing edge. 0 when the panel is hidden.
    public static func paint(
        bounds: CGRect, chipBaseline: CGFloat, libraryWidth: CGFloat, outlineWidth: CGFloat = 0
    ) -> Paint {
        let baseline = max(0, min(chipBaseline, bounds.height))
        let band = CGRect(x: bounds.minX, y: baseline,
                          width: bounds.width,
                          height: max(0, bounds.height - baseline))

        // Both panels continue far below the titlebar, so each hole extends
        // downward to keep its bottom edge clear of the band.
        let deepBelow = bounds.minY - 4

        let outlineHole: CGRect? = (outlineWidth > 0 && band.height > 0)
            ? CGRect(x: bounds.maxX - outlineWidth, y: deepBelow,
                     width: outlineWidth, height: bounds.maxY - deepBelow)
            : nil

        guard libraryWidth > 0, band.height > 0 else {
            return Paint(band: band, libraryHole: nil, outlineHole: outlineHole)
        }

        let hole = CGRect(x: bounds.minX, y: deepBelow,
                          width: max(0, libraryWidth - bounds.minX),
                          height: bounds.maxY - deepBelow)

        guard hole.width > 0, bounds.maxY > baseline else {
            return Paint(band: band, libraryHole: nil, outlineHole: outlineHole)
        }
        return Paint(band: band, libraryHole: hole, outlineHole: outlineHole)
    }
}
