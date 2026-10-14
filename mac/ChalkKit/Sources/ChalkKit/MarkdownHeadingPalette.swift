import Foundation

/// The heading palette the native host pushes over `heading-colors` when
/// "Color Markdown Headings" is on. Baked from Catppuccin, since the native
/// app has no TextMate theme to derive it from as VS Code does.
///
/// Off is an empty payload: `mountEditor` removes each missing key, so levels
/// fall back to the stylesheet.
public enum MarkdownHeadingPalette {
    /// Catppuccin Frappé: red, peach, yellow, green, sapphire, lavender.
    public static let frappe = HeadingColors(
        h1: "#e78284", h2: "#ef9f76", h3: "#e5c890",
        h4: "#a6d189", h5: "#85c1dc", h6: "#babbf1")

    /// Catppuccin Latte: the same six hues at light-theme contrast.
    public static let latte = HeadingColors(
        h1: "#d20f39", h2: "#fe640b", h3: "#df8e1d",
        h4: "#40a02b", h5: "#209fb5", h6: "#7287fd")

    /// The toggle's off state: no keys, so every level falls back to CSS.
    public static let none = HeadingColors()

    /// Callers pass the same `dark` they hand `setAppearance`, so the palette
    /// matches the page's theme.
    public static func colors(dark: Bool) -> HeadingColors { dark ? frappe : latte }
}
