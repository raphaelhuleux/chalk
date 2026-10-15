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
final class HeaderBarView: FlippedView {
    let tabStrip = HeaderTabStrip()

    private let backdrop = FlippedView()
    private var stripLeading: NSLayoutConstraint!
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
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeEffectiveAppearance() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: ChalkAppearance.themeDidChange, object: nil)
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    @objc private func themeDidChange() { refreshColors() }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            backdrop.layer?.backgroundColor = NSColor.chalkEditorBackground.cgColor
        }
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
        let wanted = ChalkMetrics.tabStripLeading + inset
        guard abs(stripLeading.constant - wanted) > 0.5 else { return }
        guard let duration, duration > 0, window != nil else {
            stripLeading.constant = wanted
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            stripLeading.constant = wanted
            layoutSubtreeIfNeeded()
        }
    }

    #if DEBUG
    /// The chips' inset past the traffic lights, as last written (the model
    /// value, even mid-animation).
    var stripLeadingInsetForTesting: CGFloat { stripLeading.constant - ChalkMetrics.tabStripLeading }
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
final class ChromeFadeView: FlippedView {
    private let gradient = CAGradientLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // Near-solid (≥92%) through the chip rows so no ghost text shows, then
        // a LINEAR ramp to zero. Keep the ramp linear and long: eased curves
        // compress it into a visible cut.
        gradient.locations = [0, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.addSublayer(gradient)
        updateColors()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChangeFade), name: ChalkAppearance.themeDidChange, object: nil)
    }

    @objc private func themeDidChangeFade() { updateColors() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bg = NSColor.chalkEditorBackground
            gradient.colors = [1.0, 0.92, 0.0].map { bg.withAlphaComponent($0).cgColor }
        }
    }
}
