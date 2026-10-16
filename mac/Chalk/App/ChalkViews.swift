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

    /// Re-resolve every cached colour. The base paints nothing.
    func refreshColors() {}
}

extension NSView {
    /// A layer colour does not follow a dynamic `NSColor`: resolve it under
    /// this view's appearance now. nil clears the fill.
    func chalkSetLayerBackground(_ color: NSColor?) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color?.cgColor
        }
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
