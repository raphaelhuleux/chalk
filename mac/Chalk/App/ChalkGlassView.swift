import AppKit
import ChalkKit

/// A VisualGlass panel: system material under a tint wash, a 0.5pt hairline
/// ring, a 1pt inset top light, and a soft drop shadow. Used by the utility
/// pill and the two palettes (denser variant).
///
/// `.paper` keeps the container (`contentView`, the appearance handling, the
/// clip) with every glass layer off, for the Library's flat tone-on-tone
/// surface: panels separate by tone, and a hairline is never doubled with a
/// shadow.
///
/// Honors Reduce Transparency: material and tint swap for a near-solid fill
/// with identical geometry.
final class ChalkGlassView: ThemedView {
    /// Subviews belong here, above the material stack and inside the clip.
    let contentView = NSView()

    struct Style {
        let material: NSVisualEffectView.Material
        let tint: NSColor
        let edge: NSColor
        let topHighlight: NSColor
        let opaqueFallback: NSColor
        /// (dark, light) shadow opacity.
        let shadowOpacity: (dark: Float, light: Float)
        let shadowRadius: CGFloat
        let shadowOffset: CGSize
        /// Light mode: replace the material with this solid fill. The light
        /// system material is gray-based, so translucent glass never reads
        /// lighter than the near-white editor. nil keeps the material (the
        /// palette floats over dimmed content, where the blur still reads).
        let lightFill: NSColor?
        /// Paper: an opaque tone, no material, no ring, no top light, no
        /// shadow, in both appearances.
        let isPaper: Bool

        static let glass = Style(
            material: .hudWindow,
            tint: .chalkGlassTint,
            edge: .chalkGlassEdge,
            topHighlight: .chalkGlassTopHighlight,
            opaqueFallback: .chalkGlassOpaque,
            shadowOpacity: (dark: 0.35, light: 0.16),
            shadowRadius: 16,
            shadowOffset: CGSize(width: 0, height: -6),
            lightFill: .chalkGlassLightFill,
            isPaper: false)

        /// The Library's surface (Paper): the chrome tone, flat, flush.
        static let paper = Style(
            material: .hudWindow,
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
            material: .popover,
            tint: .chalkPaletteTint,
            edge: .chalkPaletteEdge,
            topHighlight: .chalkPaletteTopHighlight,
            opaqueFallback: .chalkPaletteOpaque,
            shadowOpacity: (dark: 0.55, light: 0.25),
            shadowRadius: 30,
            shadowOffset: CGSize(width: 0, height: -12),
            lightFill: nil,
            isPaper: false)
    }

    private let style: Style
    private let clipView = NSView()
    /// The system material: `NSGlassEffectView` on 26, the blur before.
    private let materialView: NSView
    private let tintView = NSView()
    private let highlightView = NSView()
    private let cornerRadius: CGFloat

    /// `interactive` marks control-cluster glass (the utility pill): on 26 it
    /// is the pressable Liquid Glass variant. Container panels leave it false.
    init(style: Style, cornerRadius: CGFloat, interactive: Bool = false) {
        self.style = style
        self.cornerRadius = cornerRadius
        if #available(macOS 26.0, *), !style.isPaper {
            let glass = NSGlassEffectView()
            glass.tintColor = style.tint
            glass.cornerRadius = cornerRadius
            materialView = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = style.material
            blur.blendingMode = .behindWindow
            blur.state = .active
            materialView = blur
        }
        super.init(frame: .zero)
        wantsLayer = true
        // Shadow lives on the outer layer (clipping would cut it off).
        layer?.masksToBounds = false
        layer?.shadowRadius = style.shadowRadius
        layer?.shadowOffset = style.shadowOffset

        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = cornerRadius
        clipView.layer?.cornerCurve = .continuous
        clipView.layer?.masksToBounds = true
        clipView.layer?.borderWidth = 0.5
        clipView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clipView)

        for view in [materialView, tintView, highlightView, contentView] {
            view.wantsLayer = true
            view.translatesAutoresizingMaskIntoConstraints = false
            clipView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            clipView.topAnchor.constraint(equalTo: topAnchor),
            clipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            clipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            clipView.bottomAnchor.constraint(equalTo: bottomAnchor),
            materialView.topAnchor.constraint(equalTo: clipView.topAnchor),
            materialView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            materialView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
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
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }

    override func refreshColors() { refreshAppearance() }

    #if DEBUG
    /// The material driving the panel: NSGlassEffectView on 26, the blur before.
    var materialViewForTesting: NSView { materialView }

    /// What the panel actually paints, for the Paper surface tests: no
    /// material, no ring, no shadow, and a fill in both appearances.
    var surfaceForTesting: (materialShown: Bool, ringWidth: CGFloat,
                            shadowOpacity: Float, fill: NSColor?) {
        (!materialView.isHidden || !tintView.isHidden,
         clipView.layer?.borderWidth ?? 0, layer?.shadowOpacity ?? 0, clipFill)
    }
    #endif

    /// The clip's fill as the dynamic colour it was set from (the layer only
    /// holds a resolved CGColor).
    private var clipFill: NSColor?

    @objc private func refreshAppearance() {
        let dark = effectiveAppearance.isChalkDark
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if style.isPaper {
                // Tone only. Nothing here reacts to Reduce Transparency
                // because there is no transparency to reduce.
                materialView.isHidden = true
                tintView.isHidden = true
                highlightView.isHidden = true
                clipFill = style.opaqueFallback
                clipView.layer?.backgroundColor = style.opaqueFallback.cgColor
                clipView.layer?.borderWidth = 0
                layer?.shadowOpacity = 0
                return
            }
            let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            layer?.shadowColor = NSColor.chalkPanelShadow.cgColor
            let shadow = dark ? style.shadowOpacity.dark : style.shadowOpacity.light

            var systemGlass = false
            if #available(macOS 26.0, *) { systemGlass = materialView is NSGlassEffectView }
            if systemGlass, !reduced {
                // Real Liquid Glass draws its own edge lensing and specular,
                // and the tint rides inside the effect; the hand-rolled wash,
                // ring, top light and light-mode fill would double the chrome.
                materialView.isHidden = false
                tintView.isHidden = true
                highlightView.isHidden = true
                clipFill = nil
                clipView.layer?.backgroundColor = nil
                clipView.layer?.borderWidth = 0
                layer?.shadowOpacity = shadow * 0.5
                return
            }

            let lightFill = dark ? nil : style.lightFill
            let solid = reduced || lightFill != nil
            materialView.isHidden = solid
            tintView.isHidden = solid
            tintView.layer?.backgroundColor = style.tint.cgColor
            highlightView.isHidden = false
            highlightView.layer?.backgroundColor = style.topHighlight.cgColor
            clipFill = reduced ? style.opaqueFallback : lightFill
            clipView.layer?.backgroundColor = clipFill?.cgColor
            clipView.layer?.borderWidth = 0.5
            clipView.layer?.borderColor = style.edge.cgColor
            layer?.shadowOpacity = shadow
        }
    }
}
