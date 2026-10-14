import UIKit

/// The tab name row's host.
///
/// The row is typography on the editor surface; the only paint is an opaque
/// cover in the editor's own tone. The editor runs full-bleed under the row, so
/// without the cover scrolled text would slide up between the tab names.
///
/// The cover is cut around the Library (`setLibraryHole`) rather than drawn
/// over it, so the panel's chrome tone reaches the window's top edge. The
/// windowed row lives in the NSToolbar (see ChalkAppKitGlue/ChalkTabStrip.swift),
/// so this serves full screen and the no-glue fallback.
///
/// RootSplitViewController pins it across the whole window, above both split
/// columns, and the chips take the divider's inset (`setStripLeadingInset`).
final class HeaderBarView: UIView {
    let tabStrip = HeaderTabStrip()

    private let backdrop = UIView()
    private var stripLeading: NSLayoutConstraint!
    private var stripTrailing: NSLayoutConstraint!
    private var libraryHole: CGRect?
    /// The outline panel's slice, cut out of the paint on the trailing edge
    /// like the Library's on the leading edge.
    private var outlineHole: CGRect?
    /// The backdrop bounds the mask was last built for. The hole setters
    /// rebuild it themselves, so a layout pass only has to when this moves.
    private var maskedBounds = CGRect.null

    override init(frame: CGRect) {
        super.init(frame: frame)
        // No fill of its own: a fill behind the backdrop would be a second,
        // unmasked layer that defeats the cut-out.

        // The editor's own tone: the cover has to be opaque (full-bleed text
        // slides under it) and must not read as a bar (Paper: one paper
        // surface from the window edge down).
        backdrop.backgroundColor = .chalkEditorBackground
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        // Clipping (and thus the strip's own scroll/overflow affordance)
        // always wins over pushing itself past the window's trailing edge.
        tabStrip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(tabStrip)
        stripLeading = tabStrip.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: ChalkMetrics.tabStripLeading)
        stripTrailing = tabStrip.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor, constant: -ChalkMetrics.headerPadding)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            stripLeading,
            stripTrailing,
            // Tabs sit on the band's floor; whatever the band gains above the
            // strip (the titlebar) stays backdrop-only.
            tabStrip.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: ChalkMetrics.tabStripHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    #if DEBUG
    /// The cover's frame in the host's coordinates, and the region cut out of
    /// it. Reported rather than inferred: `band` and `bandPaint` are different
    /// things (docs/ui-correctness.md).
    var paintFrameForTesting: CGRect { backdrop.frame }
    /// What the cover paints. Paper: the editor's own tone.
    var coverFillForTesting: UIColor? { backdrop.backgroundColor }
    var paintHoleForTesting: CGRect? { libraryHole }
    var paintTrailingHoleForTesting: CGRect? { outlineHole }
    #endif

    /// Where the tab names start, measured from the host's leading edge.
    ///
    /// Only the chips move to the editor column when the Library is open; the
    /// band itself spans the window so its paint runs edge to edge
    /// (`bandSpansFullWidth`).
    func setStripLeadingInset(_ inset: CGFloat) {
        let wanted = ChalkMetrics.tabStripLeading + inset
        guard abs(stripLeading.constant - wanted) > 0.5 else { return }
        stripLeading.constant = wanted
    }

    /// The Library panel's rect, in this view's coordinates, cut out of the
    /// band's paint. Nil when no Library is showing.
    ///
    /// The band sits above both split-view column containers, so the panel has
    /// to be removed from the paint rather than drawn over
    /// (`libraryIsNeverPaintedOver`). Same shape as ChalkKit's
    /// `TitlebarBandGeometry` on the Mac side.
    func setLibraryHole(_ rect: CGRect?) {
        guard libraryHole != rect else { return }
        libraryHole = rect
        applyLibraryHole()
    }

    /// The outline panel's rect, in THIS view's coordinates, cut out of the
    /// band's paint on the trailing edge. Nil when the panel is hidden. The
    /// chips also stop at the panel: a name over the outline would sit on a
    /// surface it does not belong to, exactly like a name over the Library.
    func setOutlineHole(_ rect: CGRect?) {
        guard outlineHole != rect else { return }
        outlineHole = rect
        let inset = rect.map { max(0, bounds.maxX - $0.minX) } ?? 0
        stripTrailing.constant = -(ChalkMetrics.headerPadding + inset)
        applyLibraryHole()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The mask is in the backdrop's coordinates, so it has to be rebuilt
        // whenever the backdrop is resized, not only when the hole moves.
        guard backdrop.bounds != maskedBounds else { return }
        applyLibraryHole()
    }

    /// A touch inside a cut-out belongs to the panel that owns that surface:
    /// the host is frontmost and spans the window, and the Library's first area
    /// header sits inside its frame.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let hole = libraryHole, hole.contains(point) { return nil }
        if let hole = outlineHole, hole.contains(point) { return nil }
        return super.hitTest(point, with: event)
    }

    private func applyLibraryHole() {
        maskedBounds = backdrop.bounds
        guard libraryHole != nil || outlineHole != nil, !backdrop.bounds.isEmpty else {
            backdrop.layer.mask = nil
            return
        }
        let path = UIBezierPath(rect: backdrop.bounds)
        if let hole = libraryHole {
            path.append(UIBezierPath(rect: convert(hole, to: backdrop)))
        }
        if let hole = outlineHole {
            path.append(UIBezierPath(rect: convert(hole, to: backdrop)))
        }
        path.usesEvenOddFillRule = true

        let mask = (backdrop.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.fillColor = UIColor.black.cgColor
        mask.frame = backdrop.bounds
        mask.path = path.cgPath
        backdrop.layer.mask = mask
    }
}
