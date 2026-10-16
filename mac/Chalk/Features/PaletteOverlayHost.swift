import AppKit
import ChalkKit

/// The full-window scrim behind a palette. A click on the dim area (outside
/// the card's content) dismisses; clicks on the card reach its field and rows.
final class PaletteBackdropView: ThemedView {
    var onTapOutside: (() -> Void)?
    weak var content: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        refreshColors()
    }

    override func refreshColors() {
        chalkSetLayerBackground(.chalkScrim)
    }

    override func mouseDown(with event: NSEvent) {
        guard let content else { return }
        let point = content.convert(event.locationInWindow, from: nil)
        if content.bounds.contains(point) { return }
        onTapOutside?()
    }
}

/// One palette overlay: dim backdrop, glass card, click-to-dismiss, and the
/// reveal/hide animation. Quick Open (⌘O) and the outline palette (⌘P) each
/// own one. In-window overlays, not sheets, so opening is a view toggle with
/// no window animation. Nothing palette-specific lives here; exclusion, focus
/// return and the rest stay in `RootSplitViewController`.
final class PaletteOverlayHost {
    /// The full-window scrim, and the click-to-dismiss target.
    let backdrop = PaletteBackdropView()
    /// The glass card inside `backdrop`, animated independently of the scrim.
    private(set) var card: ChalkGlassView?
    private(set) var isVisible = false
    private weak var content: NSView?
    private var cardHeight: NSLayoutConstraint?

    /// Add the overlay to `root`, hidden, above everything the root holds at
    /// that moment. View controller containment stays with the caller.
    func mount(in root: NSView, content: NSView, onBackdropTap: @escaping () -> Void) {
        self.content = content
        backdrop.content = content
        backdrop.onTapOutside = onBackdropTap
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.isHidden = true
        root.addSubview(backdrop, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        content.translatesAutoresizingMaskIntoConstraints = false
        let cardWrap = ChalkGlassView(style: .palette, cornerRadius: ChalkMetrics.paletteRadius)
        cardWrap.translatesAutoresizingMaskIntoConstraints = false
        cardWrap.wantsLayer = true
        card = cardWrap
        backdrop.addSubview(cardWrap)
        cardWrap.contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: cardWrap.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: cardWrap.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: cardWrap.contentView.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: cardWrap.contentView.bottomAnchor),
        ])

        let width = cardWrap.widthAnchor.constraint(equalToConstant: ChalkMetrics.paletteWidth)
        width.priority = .defaultHigh
        // The card hugs its results; the palette reports its natural height via setCardHeight.
        let height = cardWrap.heightAnchor.constraint(equalToConstant: 420)
        height.priority = .defaultHigh
        cardHeight = height
        NSLayoutConstraint.activate([
            // Centered on both axes in the window (the iA Writer Quick Search placement).
            cardWrap.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            cardWrap.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            width,
            cardWrap.widthAnchor.constraint(lessThanOrEqualTo: backdrop.widthAnchor, constant: -80),
            height,
            // The height (defaultHigh) gives when the window is too short.
            cardWrap.topAnchor.constraint(greaterThanOrEqualTo: backdrop.topAnchor, constant: 40),
            cardWrap.bottomAnchor.constraint(lessThanOrEqualTo: backdrop.bottomAnchor, constant: -40),
        ])
    }

    /// The palette's reported natural height, ignored while it hasn't moved.
    func setCardHeight(_ newHeight: CGFloat) {
        guard let cardHeight, abs(cardHeight.constant - newHeight) > 0.5 else { return }
        cardHeight.constant = newHeight
    }

    private static let hiddenTransform: CATransform3D = {
        var transform = CATransform3DMakeTranslation(0, 6, 0)
        transform = CATransform3DScale(transform, 0.97, 0.97, 1)
        return transform
    }()
    private static let duration: TimeInterval = 0.10

    private var motionAllowed: Bool { backdrop.chalkMotionAllowed }

    /// Unhide instantly (layout must settle before animating), run
    /// `beforeAnimating`, then fade and scale in. Reduce Motion skips the animation.
    func present(beforeAnimating: () -> Void = {}) {
        guard let root = backdrop.superview else { return }
        isVisible = true
        backdrop.isHidden = false
        root.layoutSubtreeIfNeeded()
        beforeAnimating()
        guard motionAllowed, let card else {
            backdrop.alphaValue = 1
            card?.alphaValue = 1
            card?.layer?.transform = CATransform3DIdentity
            return
        }
        backdrop.alphaValue = 0
        card.alphaValue = 0
        // The card's layer anchors at its centre so the scale breathes from the middle.
        card.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        card.layer?.position = CGPoint(x: card.frame.midX, y: card.frame.midY)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            backdrop.animator().alphaValue = 1
            card.animator().alphaValue = 1
        }
        if let layer = card.layer {
            layer.transform = CATransform3DIdentity
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = NSValue(caTransform3D: Self.hiddenTransform)
            scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            scale.duration = Self.duration
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(scale, forKey: "chalk.palette.reveal")
        }
    }

    /// Fade out, then hide and reset. `beforeResigning` runs before the card
    /// gives up the keyboard. A reopen during the fade makes the completion
    /// skip hiding.
    func dismiss(beforeResigning: () -> Void = {}) {
        isVisible = false
        beforeResigning()
        resignContentFocus()
        guard motionAllowed, let card else {
            backdrop.isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            backdrop.animator().alphaValue = 0
            card.animator().alphaValue = 0
        }, completionHandler: { [weak self, backdrop, card] in
            guard !(self?.isVisible ?? false) else { return }
            backdrop.isHidden = true
            backdrop.alphaValue = 1
            card.alphaValue = 1
        })
    }

    /// Give up the keyboard if the card holds it (the search field's editor),
    /// so no keystroke lands in a hidden field.
    private func resignContentFocus() {
        guard let content, let window = content.window else { return }
        let responder = window.firstResponder
        let holder: NSView? = (responder as? NSTextView)?.delegate as? NSView ?? responder as? NSView
        if let holder, holder.isDescendant(of: content) {
            window.makeFirstResponder(nil)
        }
    }

    #if DEBUG
    /// The card's frame in the host root's coordinates; null while unmounted.
    var cardFrameForTesting: CGRect {
        guard let card, let root = backdrop.superview else { return .null }
        return root.convert(card.frame, from: backdrop)
    }
    #endif
}
