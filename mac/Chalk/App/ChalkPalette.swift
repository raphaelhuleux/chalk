import UIKit
import ChalkKit

/// The colour theme as a UIKit trait. The root controller and every presented sheet set it in
/// `traitOverrides` (`applyChalkAppearance`, `RootSplitViewController.applyThemePreference`), and
/// the themed colours below resolve against it the way they resolve against light/dark.
/// `affectsColorAppearance` makes UIKit re-resolve dynamic colours when it changes; CGColors cached
/// in layers still need a `registerForTraitChanges` hook (`UITraitCollection.chalkColorTraits`).
struct ChalkThemeTrait: UITraitDefinition {
    static let defaultValue = ChalkTheme.ink
    static let affectsColorAppearance = true
    static let name = "ChalkTheme"
    static let identifier = "com.huleux.chalk.theme"
}

extension UITraitCollection {
    var chalkTheme: ChalkTheme { self[ChalkThemeTrait.self] }

    /// Every trait a themed colour resolves against: light/dark and friends, plus the theme.
    static let chalkColorTraits: [UITrait] =
        systemTraitsAffectingColorAppearance + [ChalkThemeTrait.self]
}

extension UIMutableTraits {
    var chalkTheme: ChalkTheme {
        get { self[ChalkThemeTrait.self] }
        set { self[ChalkThemeTrait.self] = newValue }
    }
}

/// The app's colours. Opaque ones come from the active theme (ChalkKit `ThemePalette`, which the
/// AppKit titlebar and `PaletteParityTests` read too); translucent washes are shared by every
/// theme.
extension UIColor {
    /// The single accent: caret, tab underline, toggles.
    static let chalkAccent = themed(\.accent)

    /// Editor surface: equals the page's --vscode-editor-background, and the AppKit titlebar cover
    /// paints the same pair (`StripColor.paperFill`).
    static let chalkEditorBackground = themed(\.editorBackground)

    /// Sidebar + header sidebar-segment.
    static let chalkChromeBackground = themed(\.chromeBackground)

    static let chalkTextPrimary = themed(\.textPrimary)
    /// Matches --ink-text-body.
    static let chalkTextBody = themed(\.textBody)
    static let chalkTextSecondary = themed(\.textSecondary)
    static let chalkTextMuted = themed(\.textMuted)
    static let chalkTextFaint = themed(\.textFaint)

    /// Selected file row (spec: --selection-row).
    static let chalkRowSelection = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.09)
            : UIColor(white: 0, alpha: 0.07)
    }

    /// Settings-sheet cards (grouped sections, form fields).
    static let chalkCardBackground = themed(\.cardBackground)

    /// Separator between rows inside a settings card — softer than
    /// chalkBorderHard so rows divide without reading as drawn rules.
    static let chalkCardSeparator = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.06)
            : UIColor(white: 0, alpha: 0.06)
    }

    /// Sidebar/editor divider and footer top hairline: a subtle seam instead of
    /// the spec's near-black --border-hard, just present enough to stay legible
    /// over both the chrome and editor backgrounds.
    static let chalkBorderHard = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.09)
            : UIColor(white: 0, alpha: 0.10)
    }

    // MARK: - VisualGlass chrome
    // The chrome floats over the editor surface as translucent glass. Alpha
    // colors here are the spec verbatim; the accent family reuses chalkAccent.

    /// Chrome foreground tiers (spec --chrome-fg…): the theme's chrome glyph colour at falling
    /// alphas.
    static let chalkChromeFg = themed(\.chromeFg)
    static let chalkChromeFgSecondary = themed(\.chromeFg, alpha: (dark: 0.82, light: 0.85))
    static let chalkChromeFgTertiary = themed(\.chromeFgDim, alpha: (dark: 0.48, light: 0.50))
    static let chalkChromeFgQuaternary = themed(\.chromeFgDim, alpha: (dark: 0.40, light: 0.42))

    /// Glass material for the floating surfaces (utility pill, Quick Open,
    /// outline palette): tint over the system blur. Light is stronger than the
    /// spec's .34 white: UIKit's light material has a gray base the CSS
    /// backdrop-filter doesn't, and the panel must read lighter than the
    /// editor.
    static let chalkGlassTint = dynamicAlpha(dark: (0xFFFFFF, 0.05), light: (0xFFFFFF, 0.72))
    /// 0.5pt hairline ring around glass panels (spec --glass-edge).
    static let chalkGlassEdge = dynamicAlpha(dark: (0xFFFFFF, 0.09), light: (0x3C3228, 0.08))
    /// 1pt inset top light on glass panels (spec --glass-top-highlight).
    static let chalkGlassTopHighlight = dynamicAlpha(dark: (0xFFFFFF, 0.12), light: (0xFFFFFF, 0.85))
    /// Reduce Transparency: the glass panels' solid replacement fill.
    static let chalkGlassOpaque = themed(\.glassOpaque)
    /// Light mode's glass replacement: a touch LIGHTER than the editor, so the panel floats the
    /// way mock 1b does.
    static let chalkGlassLightFill = themed(\.glassLightFill)

    /// Glass panel drop-shadow color.
    static let chalkPanelShadow = themed(\.panelShadow)

    // MARK: - Tab name row (Paper)
    // Tabs are typography on the editor surface: label tiers, the unsaved dot,
    // icon tiers, and one accent underline. The AppKit titlebar strip wraps the
    // same palette fields in NSColor (`StripColor`).

    /// The active name's short underline: the single accent, nothing else in
    /// the chrome is saturated (Y-1).
    static let chalkTabUnderline = chalkAccent
    /// Mono labels: filename run.
    static let chalkTabLabelActive = themed(\.tabLabelActive)
    static let chalkTabLabelInactive = themed(\.tabLabelInactive)
    /// Folder-prefix run, shown only when two open tabs share a filename.
    static let chalkTabPathActive = themed(\.tabPathActive)
    static let chalkTabPathInactive = themed(\.tabPathInactive)
    /// Unsaved dot: accent on the active tab, label-grey on background tabs.
    static let chalkTabDirtyDotActive = themed(\.tabDotActive)
    static let chalkTabDirtyDotInactive = themed(\.tabDotInactive)
    /// Close × / "+" glyph tiers (spec --text-icon / --text-icon-dim).
    static let chalkTabIcon = themed(\.tabIcon)
    static let chalkTabIconDim = themed(\.tabIconDim)
    static let chalkTabIconHover = themed(\.tabIconHover)

    /// Sidebar row hover (spec --row-hover-bg).
    static let chalkRowHoverBackground = dynamicAlpha(dark: (0xFFFFFF, 0.07), light: (0x3C3228, 0.07))

    /// Accent-tinted selection (Quick Open selected row, spec --accent-selection).
    static var chalkAccentSelection: UIColor {
        UIColor { trait in chalkAccent.resolvedColor(with: trait).withAlphaComponent(0.22) }
    }

    /// Quick Open palette: denser glass than chalkGlassTint, the theme's palette tone in dark.
    /// Light leans white for the same reason (gray-based UIKit material).
    static let chalkPaletteTint = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? chalkPaletteOpaque.resolvedColor(with: trait).withAlphaComponent(0.62)
            : UIColor(white: 1, alpha: 0.80)
    }
    static let chalkPaletteEdge = dynamicAlpha(dark: (0xFFFFFF, 0.12), light: (0x3C3228, 0.10))
    static let chalkPaletteTopHighlight = dynamicAlpha(dark: (0xFFFFFF, 0.16), light: (0xFFFFFF, 0.90))
    static let chalkPaletteDivider = dynamicAlpha(dark: (0xFFFFFF, 0.10), light: (0x3C3228, 0.10))
    static let chalkPaletteOpaque = themed(\.paletteOpaque)
    /// Key badge border ("esc", "return") in the palette.
    static let chalkKeyBadgeEdge = dynamicAlpha(dark: (0xFFFFFF, 0.18), light: (0x3C3228, 0.18))
    /// The palette scrim, darker than the spec's .25 because it also carries
    /// the mock's "content dims to 45%" layer. Defined in ChalkKit
    /// (`ChromeScrim`) so the AppKit titlebar strip paints the same colour from
    /// its separate bundle.
    static let chalkScrim = UIColor { trait in
        let c = ChromeScrim.components(dark: trait.userInterfaceStyle == .dark)
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    private static func dynamicAlpha(
        dark: (hex: Int, alpha: CGFloat), light: (hex: Int, alpha: CGFloat)
    ) -> UIColor {
        UIColor { trait in
            let value = trait.userInterfaceStyle == .dark ? dark : light
            let (red, green, blue) = HexPair.rgb(hex: value.hex)
            return UIColor(red: red, green: green, blue: blue, alpha: value.alpha)
        }
    }

    /// A palette field of the trait's theme, in the trait's appearance.
    private static func themed(
        _ pick: @escaping (ThemePalette) -> HexPair,
        alpha: (dark: CGFloat, light: CGFloat) = (1, 1)
    ) -> UIColor {
        UIColor { trait in
            let isDark = trait.userInterfaceStyle == .dark
            let (red, green, blue) = pick(trait.chalkTheme.palette).components(dark: isDark)
            return UIColor(
                red: red, green: green, blue: blue, alpha: isDark ? alpha.dark : alpha.light)
        }
    }
}

extension UIFont {
    /// Synthetic oblique for the preview-tab cue. No IBM Plex Mono italic face
    /// is bundled (three weights, no slant), and swapping to the system italic
    /// mono would change family mid-strip — so slant the upright face by
    /// ChalkMetrics.obliqueSlant instead.
    static func chalkObliqueMatrix() -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: ChalkMetrics.obliqueSlant, d: 1, tx: 0, ty: 0)
    }

    /// IBM Plex Mono (spec: --font-editor) with a system-mono fallback so a
    /// missing font never breaks the UI. `oblique` slants the face in place
    /// (see chalkObliqueMatrix).
    static func chalkMono(
        size: CGFloat, weight: UIFont.Weight = .regular, oblique: Bool = false
    ) -> UIFont {
        let name: String
        switch weight {
        case .semibold, .bold: name = "IBMPlexMono-SemiBold"
        case .medium: name = "IBMPlexMono-Medium"
        default: name = "IBMPlexMono"
        }
        let upright = UIFont(name: name, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
        guard oblique else { return upright }
        // The matrix carries slant only (unit scale), so the point size still
        // travels as `size`. Note UIFont.fontDescriptor.matrix reads back as
        // identity afterwards — CTFontGetMatrix is what sees the shear.
        let slanted = upright.fontDescriptor.addingAttributes([.matrix: chalkObliqueMatrix()])
        return UIFont(descriptor: slanted, size: size)
    }
}
