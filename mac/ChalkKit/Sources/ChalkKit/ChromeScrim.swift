import CoreGraphics

/// The wash a palette lays over the window behind it.
///
/// A UIKit scrim cannot reach the AppKit titlebar, so the windowed Mac strip
/// dims itself with this same definition, compiled into the glue.
///
/// Warm, because a grey wash over the warm paper reads as dirty; dark needs
/// more alpha to separate two dark surfaces.
public enum ChromeScrim {
    public struct Components: Equatable, Sendable {
        public let red: CGFloat
        public let green: CGFloat
        public let blue: CGFloat
        public let alpha: CGFloat

        public init(hex: Int, alpha: CGFloat) {
            (red, green, blue) = HexPair.rgb(hex: hex)
            self.alpha = alpha
        }
    }

    public static let dark = Components(hex: 0x0C0A09, alpha: 0.45)
    public static let light = Components(hex: 0x2C2418, alpha: 0.22)

    public static func components(dark isDark: Bool) -> Components {
        isDark ? dark : light
    }

    /// Matches the palette's own reveal so the strip and the editor dim on one
    /// clock.
    public static let fadeDuration: Double = 0.16
}
