import XCTest
import ChalkKit
@testable import ChalkMac

/// The native colours resolve against the app's theme and the appearance
/// being drawn, so one definition (ChalkKit's `ThemePalette`) paints the
/// chrome in every theme and both appearances.
final class ThemePaletteTests: XCTestCase {
    private var incomingTheme: ChalkTheme!

    override func setUp() {
        super.setUp()
        incomingTheme = ChalkAppearance.theme
    }

    override func tearDown() {
        ChalkAppearance.theme = incomingTheme
        super.tearDown()
    }

    private func hex(_ color: NSColor, theme: ChalkTheme, dark: Bool) -> Int {
        ChalkAppearance.theme = theme
        var resolved = NSColor.black
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        let red = Int((resolved.redComponent * 255).rounded())
        let green = Int((resolved.greenComponent * 255).rounded())
        let blue = Int((resolved.blueComponent * 255).rounded())
        return (red << 16) | (green << 8) | blue
    }

    func testColoursFollowTheThemeInBothAppearances() {
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

    /// A theme change is announced, so every view caching a resolved colour re-resolves.
    func testAThemeChangeIsAnnouncedOnce() {
        ChalkAppearance.theme = .ink
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: ChalkAppearance.themeDidChange, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        ChalkAppearance.theme = .latex
        ChalkAppearance.theme = .latex
        XCTAssertEqual(posts, 1, "a repeat of the same theme is not a change")
    }

    /// The preference's forced appearance, as the window takes it: nil for Auto.
    func testThemePreferenceMapsToWindowAppearances() {
        XCTAssertNil(ThemePreference.auto.appearance)
        XCTAssertEqual(ThemePreference.light.appearance?.name, .aqua)
        XCTAssertEqual(ThemePreference.dark.appearance?.name, .darkAqua)
    }
}
