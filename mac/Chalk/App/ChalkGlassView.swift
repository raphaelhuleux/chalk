import UIKit

/// A VisualGlass panel: system blur under a tint wash, a 0.5pt hairline ring, a
/// 1pt inset top light, and a soft drop shadow. Used by the utility pill and
/// the two palettes (denser variant).
///
/// `.paper` keeps the container (`contentView`, the trait-flip handling, the
/// clip) with every glass layer off, for the Library's flat tone-on-tone
/// surface: panels separate by tone, and a hairline is never doubled with a
/// shadow.
///
/// Honors Reduce Transparency: blur and tint swap for a near-solid fill with
/// identical geometry.
final class ChalkGlassView: UIView {
    /// Subviews belong here, above the material stack and inside the clip.
    let contentView = UIView()

    struct Style {
        let material: UIBlurEffect.Style
        let tint: UIColor
        let edge: UIColor
        let topHighlight: UIColor
        let opaqueFallback: UIColor
        /// (dark, light) shadow opacity.
        let shadowOpacity: (dark: Float, light: Float)
        let shadowRadius: CGFloat
        let shadowOffset: CGSize
        /// Light mode: replace the blur with this solid fill. The light system
        /// material is gray-based, so translucent glass never reads lighter
        /// than the near-white editor. nil keeps the material (the palette
        /// floats over dimmed content, where the blur still reads correctly).
        let lightFill: UIColor?
        /// Paper: an opaque tone, no material, no ring, no top light, no
        /// shadow, in both appearances.
        let isPaper: Bool

        static let glass = Style(
            material: .systemUltraThinMaterial,
            tint: .chalkGlassTint,
            edge: .chalkGlassEdge,
            topHighlight: .chalkGlassTopHighlight,
            opaqueFallback: .chalkGlassOpaque,
            shadowOpacity: (dark: 0.35, light: 0.16),
            shadowRadius: ChalkMetrics.s(16),
            shadowOffset: CGSize(width: 0, height: ChalkMetrics.s(6)),
            lightFill: .chalkGlassLightFill,
            isPaper: false)

        /// The Library's surface (Paper): the chrome tone, flat, flush.
        static let paper = Style(
            material: .systemUltraThinMaterial,
            tint: .clear,
            edge: .clear,
            topHighlight: .clear,
            opaqueFallback: .chalkChromeBackground,
            shadowOpacity: (dark: 0, light: 0),
            shadowRadius: 0,
            shadowOffset: .zero,
            lightFill: .chalkChromeBackground,
            isPaper: true)

        static let palette = Style(
            material: .systemThinMaterial,
            tint: .chalkPaletteTint,
            edge: .chalkPaletteEdge,
            topHighlight: .chalkPaletteTopHighlight,
            opaqueFallback: .chalkPaletteOpaque,
            shadowOpacity: (dark: 0.55, light: 0.25),
            shadowRadius: ChalkMetrics.s(30),
            shadowOffset: CGSize(width: 0, height: ChalkMetrics.s(12)),
            lightFill: nil,
            isPaper: false)
    }

    private let style: Style
    private let clipView = UIView()
    private let blurView: UIVisualEffectView
    private let tintView = UIView()
    private let highlightView = UIView()

    /// `interactive` marks control-cluster glass (the utility pill): on 26 it
    /// becomes the pressable Liquid Glass variant. Container panels leave it
    /// false per the HIG.
    init(style: Style, cornerRadius: CGFloat, interactive: Bool = false) {
        self.style = style
        // OS 26: the system Liquid Glass, tinted with the style's wash so the
        // panel stays a warm surface. Earlier systems use the hand-rolled blur
        // + tint stack.
        if #available(iOS 26.0, *), !style.isPaper {
            let glass = UIGlassEffect()
            glass.tintColor = style.tint
            glass.isInteractive = interactive
            self.blurView = UIVisualEffectView(effect: glass)
        } else {
            self.blurView = UIVisualEffectView(effect: UIBlurEffect(style: style.material))
        }
        super.init(frame: .zero)
        // CGColors don't auto-resolve dynamic UIColors; re-resolve on light/dark and theme flips.
        registerForTraitChanges(UITraitCollection.chalkColorTraits) { (view: Self, _: UITraitCollection) in
            view.refreshAppearance()
        }

        // Shadow lives on the outer layer (clipping would cut it off).
        layer.shadowRadius = style.shadowRadius
        layer.shadowOffset = style.shadowOffset
        layer.masksToBounds = false

        clipView.layer.cornerRadius = cornerRadius
        clipView.layer.cornerCurve = .continuous
        clipView.layer.masksToBounds = true
        clipView.layer.borderWidth = 0.5
        clipView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clipView)

        blurView.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(blurView)
        tintView.backgroundColor = style.tint
        tintView.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(tintView)
        highlightView.backgroundColor = style.topHighlight
        highlightView.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(highlightView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(contentView)

        NSLayoutConstraint.activate([
            clipView.topAnchor.constraint(equalTo: topAnchor),
            clipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            clipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            clipView.bottomAnchor.constraint(equalTo: bottomAnchor),
            blurView.topAnchor.constraint(equalTo: clipView.topAnchor),
            blurView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            tintView.topAnchor.constraint(equalTo: clipView.topAnchor),
            tintView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            tintView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            highlightView.topAnchor.constraint(equalTo: clipView.topAnchor),
            highlightView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: cornerRadius),
            highlightView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -cornerRadius),
            highlightView.heightAnchor.constraint(equalToConstant: 1),
            contentView.topAnchor.constraint(equalTo: clipView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
        ])

        refreshAppearance()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshAppearance),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds, cornerRadius: clipView.layer.cornerRadius).cgPath
    }

    #if DEBUG
    /// The material effect driving the panel: UIGlassEffect on 26, UIBlurEffect
    /// before.
    var materialEffectForTesting: UIVisualEffect? { blurView.effect }

    /// What the panel actually paints, for the Paper surface tests: no
    /// material, no ring, no shadow, and a fill in both appearances.
    var surfaceForTesting: (materialShown: Bool, ringWidth: CGFloat,
                            shadowOpacity: Float, fill: UIColor?) {
        (!blurView.isHidden || !tintView.isHidden,
         clipView.layer.borderWidth, layer.shadowOpacity, clipView.backgroundColor)
    }
    #endif

    @objc private func refreshAppearance() {
        if style.isPaper {
            // Tone only. Nothing here reacts to Reduce Transparency because
            // there is no transparency to reduce.
            blurView.isHidden = true
            tintView.isHidden = true
            highlightView.isHidden = true
            clipView.backgroundColor = style.opaqueFallback
            clipView.layer.borderWidth = 0
            layer.shadowOpacity = 0
            return
        }
        let reduced = UIAccessibility.isReduceTransparencyEnabled
        layer.shadowColor = UIColor.chalkPanelShadow.resolvedColor(with: traitCollection).cgColor
        let shadow = traitCollection.userInterfaceStyle == .dark
            ? style.shadowOpacity.dark : style.shadowOpacity.light

        var systemGlass = false
        if #available(iOS 26.0, *) { systemGlass = blurView.effect is UIGlassEffect }
        if systemGlass, !reduced {
            // Real Liquid Glass draws its own edge lensing and specular, and
            // the tint rides inside the effect — the hand-rolled wash, ring,
            // top light, and light-mode solid fill would double the chrome.
            // Glass floats visually on its own, so the shadow softens too.
            blurView.isHidden = false
            tintView.isHidden = true
            highlightView.isHidden = true
            clipView.backgroundColor = .clear
            clipView.layer.borderWidth = 0
            layer.shadowOpacity = shadow * 0.5
            return
        }

        let lightFill = traitCollection.userInterfaceStyle != .dark ? style.lightFill : nil
        let solid = reduced || lightFill != nil
        blurView.isHidden = solid
        tintView.isHidden = solid
        highlightView.isHidden = false
        clipView.backgroundColor = reduced ? style.opaqueFallback : (lightFill ?? .clear)
        clipView.layer.borderWidth = 0.5
        clipView.layer.borderColor = style.edge.resolvedColor(with: traitCollection).cgColor
        layer.shadowOpacity = shadow
    }
}
