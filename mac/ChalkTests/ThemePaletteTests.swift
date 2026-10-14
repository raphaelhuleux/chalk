import XCTest
import ChalkKit
@testable import Chalk

/// The native colours resolve against the theme trait, so a window's theme comes from its traits
/// and never from a global.
final class ThemePaletteTests: XCTestCase {
    private func hex(_ color: UIColor, theme: ChalkTheme, dark: Bool) -> Int {
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = dark ? .dark : .light
            traits.chalkTheme = theme
        }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Int((red * 255).rounded()) << 16) | (Int((green * 255).rounded()) << 8)
            | Int((blue * 255).rounded())
    }

    func testColoursFollowTheThemeTraitInBothAppearances() {
        for theme in ChalkTheme.allCases {
            let palette = theme.palette
            for dark in [true, false] {
                XCTAssertEqual(hex(.chalkEditorBackground, theme: theme, dark: dark),
                               palette.editorBackground.hex(dark: dark), "\(theme) editor")
                XCTAssertEqual(hex(.chalkAccent, theme: theme, dark: dark),
                               palette.accent.hex(dark: dark), "\(theme) accent")
                XCTAssertEqual(hex(.chalkChromeBackground, theme: theme, dark: dark),
                               palette.chromeBackground.hex(dark: dark), "\(theme) chrome")
                XCTAssertEqual(hex(.chalkTabLabelActive, theme: theme, dark: dark),
                               palette.tabLabelActive.hex(dark: dark), "\(theme) tab label")
            }
        }
    }

    /// Without an override the trait reads Ink: the pre-theme look is the default.
    func testTheDefaultTraitIsInk() {
        XCTAssertEqual(UITraitCollection().chalkTheme, .ink)
    }

    /// The pinning helper sheets and alerts use carries the theme as well as light/dark.
    func testApplyChalkAppearancePinsTheTheme() {
        let previous = Preferences.colorTheme
        defer { Preferences.colorTheme = previous }
        Preferences.colorTheme = .latex
        let controller = UIViewController()
        controller.applyChalkAppearance()
        XCTAssertEqual(controller.traitOverrides.chalkTheme, .latex)
    }
}
