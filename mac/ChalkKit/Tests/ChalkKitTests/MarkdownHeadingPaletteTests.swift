import XCTest
@testable import ChalkKit

/// The baked heading palette the native hosts push when "Color Markdown
/// Headings" is on.
///
/// The VS Code extension has no palette of its own: `getMarkdownHeadingColors`
/// reads the ACTIVE theme's `tokenColors` at runtime, so "the same colors as
/// the extension" resolves to whatever theme the user runs. These rows are the
/// Catppuccin Frappé (dark) and Latte (light) `heading.N.markdown` foregrounds,
/// transcribed from catppuccin.catppuccin-vsc's `themes/*.json`. Hardcoded on
/// purpose: the native app ships no TextMate themes to read.
final class MarkdownHeadingPaletteTests: XCTestCase {
    func testDarkRowIsCatppuccinFrappe() {
        XCTAssertEqual(
            MarkdownHeadingPalette.colors(dark: true),
            HeadingColors(h1: "#e78284", h2: "#ef9f76", h3: "#e5c890",
                          h4: "#a6d189", h5: "#85c1dc", h6: "#babbf1"))
    }

    func testLightRowIsCatppuccinLatte() {
        XCTAssertEqual(
            MarkdownHeadingPalette.colors(dark: false),
            HeadingColors(h1: "#d20f39", h2: "#fe640b", h3: "#df8e1d",
                          h4: "#40a02b", h5: "#209fb5", h6: "#7287fd"))
    }

    /// Every level carries a color. A nil level would fall through to the
    /// stylesheet's monochrome `--ink-text-primary` floor and read as a bug
    /// (one grey heading in a colored run), not as a deliberate omission.
    func testEveryLevelIsColoredInBothAppearances() {
        for dark in [true, false] {
            let c = MarkdownHeadingPalette.colors(dark: dark)
            for (level, hex) in [c.h1, c.h2, c.h3, c.h4, c.h5, c.h6].enumerated() {
                XCTAssertNotNil(hex, "h\(level + 1) missing (dark: \(dark))")
                XCTAssertEqual(hex?.count, 7, "h\(level + 1) is not #rrggbb (dark: \(dark))")
                XCTAssertTrue(hex?.hasPrefix("#") == true,
                              "h\(level + 1) is not #rrggbb (dark: \(dark))")
            }
        }
    }

    /// The two rows are distinct: pushing the dark row onto the light theme
    /// (the bug where an appearance flip forgets to re-push) has to be visible
    /// to a test, not just to the eye.
    func testDarkAndLightAreDifferentRows() {
        XCTAssertNotEqual(MarkdownHeadingPalette.colors(dark: true),
                          MarkdownHeadingPalette.colors(dark: false))
    }

    /// "Off" is not a palette of greys — it is the ABSENCE of every key, which
    /// is what makes `mount.ts` call `removeProperty` and hand the levels back
    /// to the stylesheet.
    func testDisabledPayloadCarriesNoColors() {
        let off = MarkdownHeadingPalette.none
        XCTAssertEqual(off, HeadingColors())
        XCTAssertNil(off.h1)
        XCTAssertNil(off.h6)
    }

    /// The wire form the editor actually consumes: keys "1".."6".
    func testEncodesToNumericStringKeys() throws {
        let data = try JSONEncoder().encode(MarkdownHeadingPalette.colors(dark: true))
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(Set(obj.keys), ["1", "2", "3", "4", "5", "6"])
        XCTAssertEqual(obj["1"], "#e78284")
    }
}
