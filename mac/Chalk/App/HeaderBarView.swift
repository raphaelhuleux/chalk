import AppKit
import ChalkKit

/// The tab name row's host: the band.
///
/// The row is typography on the editor surface; the only paint is an opaque
/// cover in the editor's own tone. The editor runs full-bleed under the row, so
/// without the cover scrolled text would slide up between the tab names.
///
/// The cover is cut around the Library (`setLibraryHole`) and the outline
/// panel (`setOutlineHole`) rather than drawn over them, so each panel's
/// chrome tone reaches the window's top edge. One band for both window modes:
/// the strip sits past the traffic lights while windowed and at the same edge
/// in full screen (`ChalkMetrics.tabStripLeading`).
///
/// RootSplitViewController pins it across the whole window, above both
/// columns, and the chips take the divider's inset (`setStripLeadingInset`).
///
/// One row per tab group, leading to trailing (`setGroupColumns`). The first
/// row keeps the band's leading rules (traffic lights, Library divider); each
/// later row starts past its group's leading seam; each row stops before the
/// next group, and the last before the outline hole.
final class HeaderBarView: ThemedView {
    /// The first group's row.
    var tabStrip: HeaderTabStrip { strips[0] }
    /// Every group's row, leading to trailing.
    private(set) var strips: [HeaderTabStrip] = []
    /// A row was made for a new group: the host wires its callbacks.
    var onStripCreated: ((HeaderTabStrip) -> Void)?
    /// Leading pins of rows after the first: their group's leading seam.
    private var groupLeadings: [NSLayoutConstraint] = []
    /// Trailing caps of every row but the last: the next group's leading seam.
    private var groupTrailings: [NSLayoutConstraint] = []
    /// Each later group's leading edge, in this view.
    private var groupSeams: [CGFloat] = []

    private let backdrop = FlippedView()
    private var stripLeading: NSLayoutConstraint!
    private var stripInset: CGFloat = 0
    /// The last reading of `restingStart`; the spec constant seeds it before
    /// any window.
    private var measuredRestingStart: CGFloat = ChalkMetrics.tabStripLeading

    /// Where the names start with no Library tiled: the traffic lights'
    /// trailing edge plus `ChalkMetrics.trafficLightGap`, read off the
    /// window's own zoom button rather than the spec constant, which was
    /// measured on a short titlebar and sits 16pt short under the unified
    /// one. Measured only while the button shows: full screen hides the
    /// buttons and the last windowed reading stands (there `BandLayout`
    /// starts the row at the window's edge instead).
    var restingStart: CGFloat {
        if let zoom = window?.standardWindowButton(.zoomButton), !zoom.isHidden,
           let container = zoom.superview {
            let edge = convert(zoom.frame, from: container).maxX
            if edge > 0 { measuredRestingStart = edge + ChalkMetrics.trafficLightGap }
        }
        return measuredRestingStart
    }
    private var stripTrailing: NSLayoutConstraint!
    private var libraryHole: CGRect?
    /// The outline panel's slice, cut out of the paint on the trailing edge
    /// like the Library's on the leading edge.
    private var outlineHole: CGRect?
    /// The backdrop bounds the mask was last built for. The hole setters
    /// rebuild it themselves, so a layout pass only has to when this moves.
    private var maskedBounds = CGRect.null

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The editor's own tone: the cover has to be opaque (full-bleed text
        // slides under it) and must not read as a bar (Paper: one paper
        // surface from the window edge down).
        backdrop.wantsLayer = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        let first = makeStrip()
        stripLeading = first.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: ChalkMetrics.tabStripLeading)
        stripTrailing = trailingCap(for: first, to: trailingAnchor)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            stripLeading,
            stripTrailing,
        ])
        refreshColors()
    }

    /// A row, added and centred on the band. The row is centred: the traffic lights sit on the
    /// titlebar's centre line and the names must share it. Bottom-anchoring read 3pt low under
    /// the 52pt unified titlebar. Whatever the band gains above and below the row stays
    /// backdrop-only; where the band is the row's own height (full screen) the two coincide.
    private func makeStrip() -> HeaderTabStrip {
        let strip = HeaderTabStrip()
        strip.translatesAutoresizingMaskIntoConstraints = false
        // Clipping (and thus the strip's own scroll/overflow affordance)
        // always wins over pushing itself past the window's trailing edge.
        strip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(strip)
        NSLayoutConstraint.activate([
            strip.centerYAnchor.constraint(equalTo: centerYAnchor),
            strip.heightAnchor.constraint(equalToConstant: ChalkMetrics.tabStripHeight),
        ])
        strips.append(strip)
        return strip
    }

    /// A row's trailing cap, below the window's own size: when a hole or the next group leaves the
    /// row less than its fixed tail, the row overlaps instead of growing the window, which moved
    /// the hole and looped layout until AppKit aborted
    /// (docs/issues/2026-10-28-wide-pdf-slot-loops-layout.md).
    private func trailingCap(for strip: HeaderTabStrip, to anchor: NSLayoutXAxisAnchor,
                             constant: CGFloat = -ChalkMetrics.headerPadding) -> NSLayoutConstraint {
        let cap = strip.trailingAnchor.constraint(lessThanOrEqualTo: anchor, constant: constant)
        cap.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        return cap
    }

    /// One row per group: `seams` holds each later group's leading edge in this view, so the
    /// band shows `seams.count + 1` rows. Rows are kept in order and only added or dropped at the
    /// trailing end; the host re-assigns their groups on every update.
    func setGroupColumns(seams: [CGFloat]) {
        let seams = seams.map { $0.rounded() }
        guard seams != groupSeams || strips.count != seams.count + 1 else { return }
        groupSeams = seams
        // Same rows, moved seams (a drag, a resize): only the constants change.
        if strips.count == seams.count + 1, groupLeadings.count == seams.count {
            for (i, x) in seams.enumerated() {
                groupLeadings[i].constant = x + ChalkMetrics.tabRowDividerGap
                groupTrailings[i].constant = x - ChalkMetrics.headerPadding
            }
            return
        }
        NSLayoutConstraint.deactivate(groupLeadings + groupTrailings + [stripTrailing])
        while strips.count > seams.count + 1 { strips.removeLast().removeFromSuperview() }
        while strips.count < seams.count + 1 { onStripCreated?(makeStrip()) }
        groupLeadings = seams.enumerated().map { i, x in
            strips[i + 1].leadingAnchor.constraint(equalTo: leadingAnchor, constant: x + ChalkMetrics.tabRowDividerGap)
        }
        groupTrailings = seams.enumerated().map { i, x in
            trailingCap(for: strips[i], to: leadingAnchor, constant: x - ChalkMetrics.headerPadding)
        }
        let outline = stripTrailing.constant
        stripTrailing = trailingCap(for: strips[strips.count - 1], to: trailingAnchor, constant: outline)
        NSLayoutConstraint.activate(groupLeadings + groupTrailings + [stripTrailing])
    }

    /// The window's lights may sit elsewhere than the seed assumed.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stripLeading.constant = restingStart + stripInset
    }

    override func refreshColors() {
        paint(backdrop, background: .chalkEditorBackground)
    }

    /// The empty paper between the names drags the window, as the titlebar
    /// it replaces did.
    override var mouseDownCanMoveWindow: Bool { true }

    #if DEBUG
    /// The cover's frame in the host's coordinates, and the region cut out of
    /// it. Reported rather than inferred: `band` and `bandPaint` are different
    /// things (docs/ui-correctness.md).
    var paintFrameForTesting: CGRect { backdrop.frame }
    /// What the cover paints. Paper: the editor's own tone.
    var coverFillForTesting: NSColor? { .chalkEditorBackground }
    var paintHoleForTesting: CGRect? { libraryHole }
    var paintTrailingHoleForTesting: CGRect? { outlineHole }
    #endif

    /// Where the tab names start, measured from the host's leading edge.
    ///
    /// Only the chips move to the editor column when the Library is open; the
    /// band itself spans the window so its paint runs edge to edge
    /// (`bandSpansFullWidth`).
    ///
    /// `animatedOver` is the sidebar slide's clock: the chips ride the
    /// column's motion (docs/motion.md). Every other caller passes nil and the
    /// write is instant; a live divider drag is dense small deltas.
    func setStripLeadingInset(_ inset: CGFloat, animatedOver duration: TimeInterval? = nil) {
        stripInset = inset
        let wanted = restingStart + inset
        guard abs(stripLeading.constant - wanted) > 0.5 else { return }
        guard let duration, duration > 0 else {
            stripLeading.constant = wanted
            return
        }
        chalkAnimateStyle(over: duration, timing: .easeOut) { [self] in
            stripLeading.constant = wanted
            layoutSubtreeIfNeeded()
        }
    }

    #if DEBUG
    /// The chips' inset past the traffic lights, as last written (the model
    /// value, even mid-animation).
    var stripLeadingInsetForTesting: CGFloat { stripLeading.constant - measuredRestingStart }
    #endif

    /// The Library panel's rect, in this view's coordinates, cut out of the
    /// band's paint. Nil when no Library is showing (`libraryIsNeverPaintedOver`).
    func setLibraryHole(_ rect: CGRect?) {
        guard libraryHole != rect else { return }
        libraryHole = rect
        applyHoles()
    }

    /// The outline panel's rect, in THIS view's coordinates, cut out of the
    /// band's paint on the trailing edge. Nil when the panel is hidden. The
    /// chips also stop at the panel.
    func setOutlineHole(_ rect: CGRect?) {
        guard outlineHole != rect else { return }
        outlineHole = rect
        let inset = rect.map { max(0, bounds.maxX - $0.minX) } ?? 0
        stripTrailing.constant = -(ChalkMetrics.headerPadding + inset)
        applyHoles()
    }

    /// Where the first row's narrowest readable strip ends, with the band's trailing padding, in
    /// this view: an outline hole that starts before this hides the tab names. Never read off the
    /// group seams: the seams follow the slot, so a limit from them would feed back into itself.
    var stripReadableExtent: CGFloat {
        stripLeading.constant + HeaderTabStrip.readableWidth + ChalkMetrics.headerPadding
    }

    override func layout() {
        super.layout()
        // The mask is in the backdrop's coordinates, so it has to be rebuilt
        // whenever the backdrop is resized, not only when the hole moves.
        guard backdrop.bounds != maskedBounds else { return }
        applyHoles()
    }

    /// A click inside a cut-out belongs to the panel that owns that surface:
    /// the band is frontmost and spans the window, and the Library's first
    /// area header sits inside its frame.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let hole = libraryHole, hole.contains(local) { return nil }
        if let hole = outlineHole, hole.contains(local) { return nil }
        return super.hitTest(point)
    }

    private func applyHoles() {
        maskedBounds = backdrop.bounds
        guard libraryHole != nil || outlineHole != nil, !backdrop.bounds.isEmpty else {
            backdrop.layer?.mask = nil
            return
        }
        let path = CGMutablePath()
        path.addRect(backdrop.bounds)
        if let hole = libraryHole { path.addRect(convert(hole, to: backdrop)) }
        if let hole = outlineHole { path.addRect(convert(hole, to: backdrop)) }

        let mask = (backdrop.layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        mask.frame = backdrop.bounds
        mask.path = path
        backdrop.layer?.mask = mask
    }
}

/// Gradient under the tab band, editor background dissolving to clear, so
/// text fades out before it slides under the chips. Never intercepts events.
final class ChromeFadeView: ThemedView {
    private let gradient = CAGradientLayer()

    /// The ramp's alpha samples, top to bottom: 1 − smoothstep. Zero slope at
    /// both ends, so the ramp meets neither the solid part nor the clear paper
    /// at a crease; a linear ramp shows a Mach band at each end.
    private static let rampAlphas: [CGFloat] = (0...8).map { i in
        let t = CGFloat(i) / 8
        return 1 - t * t * (3 - 2 * t)
    }

    /// Solid from the top down to here, then the ramp to the bottom edge.
    /// The band's opaque cover ends at its floor, so the ramp must start
    /// there at full strength or the floor reads as a step.
    var solidHeight: CGFloat = 0 {
        didSet { if solidHeight != oldValue { needsLayout = true } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.addSublayer(gradient)
        refreshColors()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        let solid = bounds.height > 0 ? min(1, max(0, solidHeight / bounds.height)) : 0
        let ramp = Self.rampAlphas.indices.map { i in
            NSNumber(value: Double(solid + (1 - solid) * CGFloat(i) / CGFloat(Self.rampAlphas.count - 1)))
        }
        gradient.locations = [0] + ramp
        CATransaction.commit()
    }

    override func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bg = NSColor.chalkEditorBackground
            gradient.colors = ([1] + Self.rampAlphas).map { bg.withAlphaComponent($0).cgColor }
        }
    }
}
