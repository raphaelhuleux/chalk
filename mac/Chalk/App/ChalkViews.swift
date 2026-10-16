import AppKit

/// A view whose origin is top-left, so the chrome's geometry reads the way the
/// spec and the invariant catalogue state it (y grows downward).
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A flipped view that caches resolved colours (layer fills, gradient stops).
/// `refreshColors()` runs on every light/dark flip and on every theme change;
/// a theme is not an `NSAppearance`, so only `ChalkAppearance.themeDidChange`
/// announces it. Subclasses call it once at the end of their init, after the
/// layers it writes exist.
class ThemedView: FlippedView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: ChalkAppearance.themeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc func themeDidChange() { refreshColors() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    /// Re-resolve every cached colour. The base paints nothing. A child's
    /// layer is painted with `paint(_:background:)`, never with the child's
    /// own appearance: see `chalkSetLayerBackground`.
    func refreshColors() {}

    /// Resolve `color` under THIS view's appearance and write it to `child`'s layer.
    func paint(_ child: NSView, background color: NSColor?) {
        child.chalkSetLayerBackground(color, under: effectiveAppearance)
    }
}

extension NSView {
    /// A layer colour does not follow a dynamic `NSColor`: resolve it now,
    /// under `appearance`. nil clears the fill.
    ///
    /// Pass the appearance of the view whose `viewDidChangeEffectiveAppearance`
    /// is running. A descendant's `effectiveAppearance` still reports the old
    /// appearance inside its ancestor's callback, and a view not yet in the
    /// hierarchy reports the app's, so resolving under the receiver's own
    /// appearance there paints the previous light/dark state (the band and the
    /// Settings cards came up dark in light mode that way).
    func chalkSetLayerBackground(_ color: NSColor?, under appearance: NSAppearance) {
        appearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color?.cgColor
        }
    }

    /// `chalkSetLayerBackground(_:under:)` under the receiver's own appearance:
    /// for a view painting itself, outside any ancestor's appearance callback.
    func chalkSetLayerBackground(_ color: NSColor?) {
        chalkSetLayerBackground(color, under: effectiveAppearance)
    }

    /// Whether a style change here may animate: hosted, and Reduce Motion off.
    var chalkMotionAllowed: Bool {
        window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Apply `change` with implicit animation over `duration`, or at once where
    /// motion is not allowed.
    func chalkAnimateStyle(over duration: TimeInterval, timing: CAMediaTimingFunctionName? = nil,
                           _ change: @escaping () -> Void) {
        guard chalkMotionAllowed else {
            change()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            if let timing { context.timingFunction = CAMediaTimingFunction(name: timing) }
            context.allowsImplicitAnimation = true
            change()
        }
    }
}

extension NSTableRowView {
    /// The rounded selection or hover wash a row paints itself, with the
    /// table's own highlight off.
    func fillChalkPill(_ color: NSColor, insetX: CGFloat = 0, insetY: CGFloat, radius: CGFloat) {
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: insetX, dy: insetY),
                     xRadius: radius, yRadius: radius).fill()
    }
}

extension NSImageView {
    /// A bitmap standing in for live pixels during a transition: stretched to
    /// `frame`, layer-backed so it can fade.
    static func chalkSnapshot(_ image: NSImage, frame: NSRect) -> NSImageView {
        let bitmap = NSImageView(image: image)
        bitmap.imageScaling = .scaleAxesIndependently
        bitmap.wantsLayer = true
        bitmap.frame = frame
        return bitmap
    }
}
