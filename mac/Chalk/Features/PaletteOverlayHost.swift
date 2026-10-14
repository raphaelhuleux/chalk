import UIKit

/// One palette overlay: dim backdrop, glass card, tap-to-dismiss, and the reveal/hide animation.
/// Quick Open (⌘O) and the outline palette (⌘P) each own one. In-window overlays, not sheets: on
/// Mac Catalyst a `.formSheet` animates even with `animated: false`. Nothing palette-specific
/// lives here; exclusion, focus return and the rest stay in `RootSplitViewController`.
final class PaletteOverlayHost: NSObject, UIGestureRecognizerDelegate {
    /// The full-window scrim, and the tap-to-dismiss target.
    let backdrop = UIView()
    /// The glass card inside `backdrop`, animated independently of the scrim.
    private(set) var card: UIView?
    private(set) var isVisible = false
    /// The palette's view, held for the tap-outside rule and to resign the search field.
    private weak var content: UIView?
    private var cardHeight: NSLayoutConstraint?
    private var onBackdropTap: (() -> Void)?

    /// Add the overlay to `root`, hidden. View controller containment stays with the caller.
    func mount(in root: UIView, content: UIView, onBackdropTap: @escaping () -> Void) {
        self.content = content
        self.onBackdropTap = onBackdropTap
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.backgroundColor = .chalkScrim
        backdrop.isHidden = true
        root.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(backdropTapped))
        tap.delegate = self
        backdrop.addGestureRecognizer(tap)

        content.translatesAutoresizingMaskIntoConstraints = false
        let cardWrap = ChalkGlassView(style: .palette, cornerRadius: ChalkMetrics.paletteRadius)
        cardWrap.translatesAutoresizingMaskIntoConstraints = false
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
        let area = paletteArea()
        NSLayoutConstraint.activate([
            cardWrap.centerXAnchor.constraint(equalTo: area.centerXAnchor),
            cardWrap.centerYAnchor.constraint(equalTo: area.centerYAnchor),
            width,
            cardWrap.widthAnchor.constraint(lessThanOrEqualTo: area.widthAnchor, constant: -80),
            height,
            // The height (defaultHigh) gives when the area is too short.
            cardWrap.topAnchor.constraint(greaterThanOrEqualTo: area.topAnchor, constant: 40),
            cardWrap.bottomAnchor.constraint(lessThanOrEqualTo: area.bottomAnchor, constant: -40),
        ])
    }

    /// The palette VC's reported natural height, ignored while it hasn't moved.
    func setCardHeight(_ newHeight: CGFloat) {
        guard let cardHeight, abs(cardHeight.constant - newHeight) > 0.5 else { return }
        cardHeight.constant = newHeight
    }

    // The card centers in the backdrop, which covers the whole window.
    private func paletteArea() -> UILayoutGuide {
        let area = UILayoutGuide()
        backdrop.addLayoutGuide(area)
        NSLayoutConstraint.activate([
            area.topAnchor.constraint(equalTo: backdrop.topAnchor),
            area.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            area.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            area.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        return area
    }

    private static let hiddenTransform =
        CGAffineTransform(translationX: 0, y: 6).scaledBy(x: 0.97, y: 0.97)

    /// Unhide instantly (layout must settle before animating), run `beforeAnimating`, then fade
    /// and scale in. Reduce Motion skips the animation.
    func present(beforeAnimating: () -> Void = {}) {
        guard let root = backdrop.superview else { return }
        isVisible = true
        UIView.performWithoutAnimation {
            root.bringSubviewToFront(backdrop)
            backdrop.isHidden = false
            root.layoutIfNeeded()
        }
        beforeAnimating()
        guard !UIAccessibility.isReduceMotionEnabled else {
            backdrop.alpha = 1
            card?.alpha = 1
            card?.transform = .identity
            return
        }
        backdrop.alpha = 0
        card?.alpha = 0
        card?.transform = Self.hiddenTransform
        UIView.animate(withDuration: 0.10,
                       delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState]) { [backdrop, card] in
            backdrop.alpha = 1
            card?.alpha = 1
            card?.transform = .identity
        }
    }

    /// Fade out, then hide and reset. `beforeResigning` runs before the card gives up the
    /// keyboard. A reopen during the fade makes the completion skip hiding.
    func dismiss(beforeResigning: () -> Void = {}) {
        isVisible = false
        beforeResigning()
        content?.endEditing(true) // resign the search field
        guard !UIAccessibility.isReduceMotionEnabled else {
            UIView.performWithoutAnimation { backdrop.isHidden = true }
            return
        }
        UIView.animate(withDuration: 0.10,
                       delay: 0,
                       options: [.curveEaseIn, .beginFromCurrentState]) { [backdrop, card] in
            backdrop.alpha = 0
            card?.alpha = 0
            card?.transform = Self.hiddenTransform
        } completion: { [weak self, backdrop, card] _ in
            guard !(self?.isVisible ?? false) else { return }
            backdrop.isHidden = true
            backdrop.alpha = 1
            card?.alpha = 1
            card?.transform = .identity
        }
    }

    @objc private func backdropTapped() { onBackdropTap?() }

    // Tap-to-dismiss fires only on the dim area, so taps still reach the card's field and rows.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        guard isVisible, let content else { return false }
        return !content.bounds.contains(touch.location(in: content))
    }
}
