import AppKit
import CoreText
import ChalkKit

/// The colour theme every themed colour resolves against. AppKit has no custom trait, and the
/// theme is one preference for the whole app, so it is process state: the shell writes it when the
/// preference changes and redraws, and the dynamic providers below read it at resolve time.
enum ChalkAppearance {
    static var theme: ChalkTheme = Preferences.colorTheme {
        didSet {
            guard theme != oldValue else { return }
            NotificationCenter.default.post(name: themeDidChange, object: nil)
        }
    }

    /// Posted on the main thread when `theme` changes. A theme is not an
    /// `NSAppearance`, so `viewDidChangeEffectiveAppearance` never fires for
    /// it: every view that caches a resolved colour re-resolves on this.
    static let themeDidChange = Notification.Name("chalk.appearance.themeDidChange")
}

extension NSAppearance {
    /// Whether this appearance is one of the dark ones, the way the page's `data-theme` sees it.
    var isChalkDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// The app's colours. Opaque ones come from the active theme (ChalkKit `ThemePalette`, which the
/// page's stylesheet is checked against); translucent washes are shared by every theme.
extension NSColor {
    /// The single accent: caret, tab underline, toggles.
    static let chalkAccent = themed(\.accent)

    /// Editor surface: equals the page's --vscode-editor-background.
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
    static let chalkRowSelection = dynamicAlpha(dark: (0xFFFFFF, 0.09), light: (0x000000, 0.07))

    /// Settings cards (grouped sections, form fields).
    static let chalkCardBackground = themed(\.cardBackground)

    /// Separator between rows inside a settings card: softer than chalkBorderHard so rows divide
    /// without reading as drawn rules.
    static let chalkCardSeparator = dynamicAlpha(dark: (0xFFFFFF, 0.06), light: (0x000000, 0.06))

    /// Sidebar/editor divider and footer top hairline: a subtle seam instead of the spec's
    /// near-black --border-hard, just present enough to stay legible over both the chrome and
    /// editor backgrounds.
    static let chalkBorderHard = dynamicAlpha(dark: (0xFFFFFF, 0.09), light: (0x000000, 0.10))

    // MARK: - VisualGlass chrome
    // The chrome floats over the editor surface as translucent glass. Alpha colours here are the
    // spec verbatim; the accent family reuses chalkAccent.

    /// Chrome foreground tiers (spec --chrome-fg…): the theme's chrome glyph colour at falling
    /// alphas.
    static let chalkChromeFg = themed(\.chromeFg)
    static let chalkChromeFgSecondary = themed(\.chromeFg, alpha: (dark: 0.82, light: 0.85))
    static let chalkChromeFgTertiary = themed(\.chromeFgDim, alpha: (dark: 0.48, light: 0.50))
    static let chalkChromeFgQuaternary = themed(\.chromeFgDim, alpha: (dark: 0.40, light: 0.42))

    /// Glass material for the floating surfaces (utility pill, Quick Open, outline palette): tint
    /// over the system blur. Light is stronger than the spec's .34 white: the light material has a
    /// gray base the CSS backdrop-filter doesn't, and the panel must read lighter than the editor.
    static let chalkGlassTint = dynamicAlpha(dark: (0xFFFFFF, 0.05), light: (0xFFFFFF, 0.72))
    /// 0.5pt hairline ring around glass panels (spec --glass-edge).
    static let chalkGlassEdge = dynamicAlpha(dark: (0xFFFFFF, 0.09), light: (0x3C3228, 0.08))
    /// 1pt inset top light on glass panels (spec --glass-top-highlight).
    static let chalkGlassTopHighlight = dynamicAlpha(dark: (0xFFFFFF, 0.12), light: (0xFFFFFF, 0.85))
    /// Reduce Transparency: the glass panels' solid replacement fill.
    static let chalkGlassOpaque = themed(\.glassOpaque)
    /// Light mode's glass replacement: a touch LIGHTER than the editor, so the panel floats.
    static let chalkGlassLightFill = themed(\.glassLightFill)

    /// Glass panel drop-shadow colour.
    static let chalkPanelShadow = themed(\.panelShadow)

    // MARK: - Tab name row (Paper)
    // Tabs are typography on the editor surface: label tiers, the unsaved dot, icon tiers, and one
    // accent underline.

    /// The active name's short underline: the single accent, nothing else in the chrome is
    /// saturated (Y-1).
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
    static let chalkAccentSelection = themed(\.accent, alpha: (dark: 0.22, light: 0.22))

    /// Quick Open palette: denser glass than chalkGlassTint, the theme's palette tone in dark.
    /// Light leans white for the same reason (gray-based material).
    static let chalkPaletteTint = NSColor(name: nil) { appearance in
        if appearance.isChalkDark {
            let (red, green, blue) = ChalkAppearance.theme.palette.paletteOpaque.components(dark: true)
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 0.62)
        }
        return NSColor(white: 1, alpha: 0.80)
    }
    static let chalkPaletteEdge = dynamicAlpha(dark: (0xFFFFFF, 0.12), light: (0x3C3228, 0.10))
    static let chalkPaletteTopHighlight = dynamicAlpha(dark: (0xFFFFFF, 0.16), light: (0xFFFFFF, 0.90))
    static let chalkPaletteDivider = dynamicAlpha(dark: (0xFFFFFF, 0.10), light: (0x3C3228, 0.10))
    static let chalkPaletteOpaque = themed(\.paletteOpaque)
    /// Key badge border ("esc", "return") in the palette.
    static let chalkKeyBadgeEdge = dynamicAlpha(dark: (0xFFFFFF, 0.18), light: (0x3C3228, 0.18))
    /// The palette scrim, darker than the spec's .25 because it also carries the mock's "content
    /// dims to 45%" layer. Defined in ChalkKit (`ChromeScrim`).
    static let chalkScrim = NSColor(name: nil) { appearance in
        let c = ChromeScrim.components(dark: appearance.isChalkDark)
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    private static func dynamicAlpha(
        dark: (hex: Int, alpha: CGFloat), light: (hex: Int, alpha: CGFloat)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.isChalkDark ? dark : light
            let (red, green, blue) = HexPair.rgb(hex: value.hex)
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: value.alpha)
        }
    }

    /// A palette field of the current theme, in the appearance being resolved.
    private static func themed(
        _ pick: @escaping (ThemePalette) -> HexPair,
        alpha: (dark: CGFloat, light: CGFloat) = (1, 1)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.isChalkDark
            let (red, green, blue) = pick(ChalkAppearance.theme.palette).components(dark: isDark)
            return NSColor(
                srgbRed: red, green: green, blue: blue, alpha: isDark ? alpha.dark : alpha.light)
        }
    }
}

extension NSFont {
    /// Synthetic oblique for the preview-tab cue. No IBM Plex Mono italic face is bundled (three
    /// weights, no slant), and swapping to the system italic mono would change family mid-strip,
    /// so slant the upright face by `TabStripMetrics.obliqueSlant` instead.
    static func chalkObliqueTransform() -> AffineTransform {
        AffineTransform(m11: 1, m12: 0, m21: TabStripMetrics.obliqueSlant, m22: 1, tX: 0, tY: 0)
    }

    /// IBM Plex Mono (spec: --font-editor) with a system-mono fallback so a missing font never
    /// breaks the UI. `oblique` slants the face in place (see chalkObliqueTransform).
    static func chalkMono(
        size: CGFloat, weight: NSFont.Weight = .regular, oblique: Bool = false
    ) -> NSFont {
        let names: [String]
        switch weight {
        case .semibold, .bold: names = ["IBMPlexMono-SemiBold"]
        case .medium: names = ["IBMPlexMono-Medium"]
        default: names = ["IBMPlexMono-Regular", "IBMPlexMono"] // the regular face's PostScript name first
        }
        let upright = names.lazy.compactMap { NSFont(name: $0, size: size) }.first
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
        guard oblique else { return upright }
        // Through Core Text: `NSFont(descriptor:textTransform:)` reports a
        // 1pt font for a bundled face under a unit shear and squares the size
        // under a sized one, while a descriptor `.matrix` beside a size
        // reports 1pt too (TabLabelFontTests pins the size and the shear).
        var shear = CGAffineTransform(a: 1, b: 0, c: TabStripMetrics.obliqueSlant, d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(upright as CTFont, size, &shear, nil) as NSFont
    }
}
