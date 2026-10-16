import CoreGraphics

/// A colour theme. Each has a dark and a light variant; the app's Light/Dark/Auto preference picks
/// which one shows.
///
/// The raw value is the persisted preference and the page's `data-palette` attribute, whose blocks
/// in web/src/chalk-theme.css must agree with `palette` (`PaletteParityTests`). Keep it
/// Foundation/CoreGraphics only so `swift test` reaches it.
public enum ChalkTheme: String, CaseIterable, Sendable {
    case ink, atom, catppuccin, latex

    public var title: String {
        switch self {
        case .ink: return "Ink"
        case .atom: return "Atom"
        case .catppuccin: return "Catppuccin"
        case .latex: return "LaTeX"
        }
    }

    /// editor-core's `markdownStyle`: the LaTeX theme lays Markdown lists and quotes out by depth
    /// so they align in its proportional font; the monospace themes keep styled source.
    public var markdownStyle: String {
        self == .latex ? "typeset" : "source"
    }

    public var palette: ThemePalette {
        switch self {
        case .ink: return .ink
        case .atom: return .atom
        case .catppuccin: return .catppuccin
        case .latex: return .latex
        }
    }
}

/// One colour as a (dark, light) sRGB hex pair, alpha implied opaque.
public struct HexPair: Equatable, Sendable {
    public let dark: Int
    public let light: Int

    public init(dark: Int, light: Int) {
        self.dark = dark
        self.light = light
    }

    /// The hex for one appearance.
    public func hex(dark isDark: Bool) -> Int {
        isDark ? dark : light
    }

    /// The sRGB components for one appearance.
    public func components(dark isDark: Bool) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        Self.rgb(hex: hex(dark: isDark))
    }

    /// A 0xRRGGBB value as 0…1 sRGB components: the one hex decoder for the
    /// chrome's colours on both toolkits.
    public static func rgb(hex: Int) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        (CGFloat((hex >> 16) & 0xFF) / 255,
         CGFloat((hex >> 8) & 0xFF) / 255,
         CGFloat(hex & 0xFF) / 255)
    }
}

/// Every opaque colour the native chrome takes from a theme. Translucent washes and hairlines
/// (glass edges, row hover, scrim) are white or black at an alpha and stay shared.
public struct ThemePalette: Equatable, Sendable {
    // Shared with the page: each equals a `--ink-*` variable in that theme's chalk-theme.css block.
    public var editorBackground: HexPair
    public var accent: HexPair
    public var textPrimary: HexPair
    public var textBody: HexPair
    public var textSecondary: HexPair
    public var textMuted: HexPair
    public var textFaint: HexPair
    public var textGhost: HexPair

    // Native chrome only.
    /// Sidebar and Settings background. Its dark value is also the page's suggest-widget
    /// background.
    public var chromeBackground: HexPair
    /// Settings cards: a step off the chrome so sections read as raised panels.
    public var cardBackground: HexPair
    /// Reduce Transparency fill for the glass panels.
    public var glassOpaque: HexPair
    /// Light mode's glass replacement, lighter than the editor so the panel floats.
    public var glassLightFill: HexPair
    /// Quick Open / outline palette: tint base and Reduce Transparency fill.
    public var paletteOpaque: HexPair
    public var panelShadow: HexPair
    /// Chrome glyph colour; the tiers below it are this at lower alphas.
    public var chromeFg: HexPair
    /// The tertiary and quaternary chrome tiers' base.
    public var chromeFgDim: HexPair

    // The tab row.
    public var tabLabelActive: HexPair
    public var tabLabelInactive: HexPair
    /// Folder-prefix run, shown only when two open tabs share a filename.
    public var tabPathActive: HexPair
    public var tabPathInactive: HexPair
    /// The unsaved dot.
    public var tabDotActive: HexPair
    public var tabDotInactive: HexPair
    /// Close × / "+" glyph tiers.
    public var tabIcon: HexPair
    public var tabIconDim: HexPair
    public var tabIconHover: HexPair
}

extension ThemePalette {
    /// The original "Ink" palette (handoff/chalk-design.css). Dark is the spec verbatim; light
    /// keeps the app's earlier light look.
    public static let ink = ThemePalette(
        editorBackground: HexPair(dark: 0x1B1A18, light: 0xF8F5EE),
        accent: HexPair(dark: 0xE2955C, light: 0xD24A3E),
        textPrimary: HexPair(dark: 0xF2EFE9, light: 0x1F1E24),
        textBody: HexPair(dark: 0xE6E2DA, light: 0x3A3942),
        textSecondary: HexPair(dark: 0xA5A19A, light: 0x6F6A61),
        textMuted: HexPair(dark: 0x8F8B84, light: 0x8A857D),
        textFaint: HexPair(dark: 0x6B6862, light: 0xA39D92),
        textGhost: HexPair(dark: 0x57534C, light: 0xB8B1A2),
        chromeBackground: HexPair(dark: 0x161513, light: 0xF1EFEC),
        cardBackground: HexPair(dark: 0x211F1C, light: 0xFDFBF6),
        glassOpaque: HexPair(dark: 0x26231F, light: 0xEFECE6),
        glassLightFill: HexPair(dark: 0x26231F, light: 0xFDFBF6),
        paletteOpaque: HexPair(dark: 0x2C2824, light: 0xEFECE6),
        // Light is a warm dark: pure black reads dirty on cream.
        panelShadow: HexPair(dark: 0x000000, light: 0x322A20),
        chromeFg: HexPair(dark: 0xECE8E1, light: 0x33302A),
        chromeFgDim: HexPair(dark: 0xECE8E1, light: 0x2C2822),
        tabLabelActive: HexPair(dark: 0xECE9E3, light: 0x33302A),
        tabLabelInactive: HexPair(dark: 0x8B8783, light: 0x8A857D),
        tabPathActive: HexPair(dark: 0x6F6B66, light: 0xA29B8F),
        tabPathInactive: HexPair(dark: 0x5F5C58, light: 0xB0A99D),
        tabDotActive: HexPair(dark: 0xD98A3C, light: 0xC06B26),
        tabDotInactive: HexPair(dark: 0x8B8783, light: 0x8A857D),
        tabIcon: HexPair(dark: 0x6F6B66, light: 0x8A857D),
        tabIconDim: HexPair(dark: 0x4D4A46, light: 0xB0A99D),
        tabIconHover: HexPair(dark: 0xC9C5BE, light: 0x4A463F))

    /// Atom's One Dark / One Light, after kognise/obsidian-atom.
    public static let atom = derived(
        editor: HexPair(dark: 0x272B34, light: 0xFAFAFA),
        chrome: HexPair(dark: 0x20242B, light: 0xEAEAEB),
        card: HexPair(dark: 0x2C313A, light: 0xFFFFFF),
        raised: HexPair(dark: 0x323843, light: 0xF0F0F1),
        primary: HexPair(dark: 0xE6E7E9, light: 0x24262D),
        body: HexPair(dark: 0xDCDDDE, light: 0x383A42),
        secondary: HexPair(dark: 0xABB2BF, light: 0x696C77),
        muted: HexPair(dark: 0x828997, light: 0x8E8E90),
        faint: HexPair(dark: 0x5C6370, light: 0xA0A1A7),
        ghost: HexPair(dark: 0x4B5263, light: 0xC2C2C3),
        accent: HexPair(dark: 0x61AFEF, light: 0x1592FF),
        shadow: HexPair(dark: 0x000000, light: 0x1F2026))

    /// Catppuccin: Frappé for dark, Latte for light, mauve accent (catppuccin/obsidian).
    public static let catppuccin = derived(
        editor: HexPair(dark: 0x303446, light: 0xEFF1F5),      // base
        chrome: HexPair(dark: 0x292C3C, light: 0xE6E9EF),      // mantle
        card: HexPair(dark: 0x383C50, light: 0xF7F8FA),
        raised: HexPair(dark: 0x414559, light: 0xE6E9EF),      // surface0 / mantle
        primary: HexPair(dark: 0xC6D0F5, light: 0x4C4F69),     // text
        body: HexPair(dark: 0xB5BFE2, light: 0x5C5F77),        // subtext1
        secondary: HexPair(dark: 0xA5ADCE, light: 0x6C6F85),   // subtext0
        muted: HexPair(dark: 0x949CBB, light: 0x7C7F93),       // overlay2
        faint: HexPair(dark: 0x737994, light: 0x9CA0B0),       // overlay0
        ghost: HexPair(dark: 0x626880, light: 0xACB0BE),       // surface2
        accent: HexPair(dark: 0xCA9EE6, light: 0x8839EF),      // mauve
        shadow: HexPair(dark: 0x232634, light: 0x4C4F69))      // crust / text

    /// A typeset page: Obsidian's default neutrals behind Palatino (the page sets the font), after
    /// benf2004/Obsidian-LaTeX-Theme, with its hyperref-style blue.
    public static let latex = derived(
        editor: HexPair(dark: 0x1E1E1E, light: 0xFFFFFF),
        chrome: HexPair(dark: 0x262626, light: 0xF6F6F6),
        card: HexPair(dark: 0x303030, light: 0xFFFFFF),
        raised: HexPair(dark: 0x2E2E2E, light: 0xF2F2F2),
        primary: HexPair(dark: 0xEDEDED, light: 0x000000),
        body: HexPair(dark: 0xDADADA, light: 0x1A1A1A),
        secondary: HexPair(dark: 0xB3B3B3, light: 0x5C5C5C),
        muted: HexPair(dark: 0x999999, light: 0x808080),
        faint: HexPair(dark: 0x666666, light: 0xABABAB),
        ghost: HexPair(dark: 0x4D4D4D, light: 0xC8C8C8),
        accent: HexPair(dark: 0x4F8FE6, light: 0x2875D9),
        shadow: HexPair(dark: 0x000000, light: 0x000000))

    /// A full palette from a theme's base tones. The chrome and the tab row reuse the text ramp:
    /// labels are primary/muted, icons faint/ghost, the unsaved dot is the accent.
    static func derived(
        editor: HexPair, chrome: HexPair, card: HexPair, raised: HexPair,
        primary: HexPair, body: HexPair, secondary: HexPair, muted: HexPair,
        faint: HexPair, ghost: HexPair, accent: HexPair, shadow: HexPair
    ) -> ThemePalette {
        ThemePalette(
            editorBackground: editor,
            accent: accent,
            textPrimary: primary,
            textBody: body,
            textSecondary: secondary,
            textMuted: muted,
            textFaint: faint,
            textGhost: ghost,
            chromeBackground: chrome,
            cardBackground: card,
            glassOpaque: raised,
            glassLightFill: HexPair(dark: raised.dark, light: card.light),
            paletteOpaque: raised,
            panelShadow: shadow,
            chromeFg: primary,
            chromeFgDim: primary,
            tabLabelActive: primary,
            tabLabelInactive: muted,
            tabPathActive: faint,
            tabPathInactive: ghost,
            tabDotActive: accent,
            tabDotInactive: muted,
            tabIcon: faint,
            tabIconDim: ghost,
            tabIconHover: body)
    }
}
