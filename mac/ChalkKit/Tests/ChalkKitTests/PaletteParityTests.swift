import XCTest
@testable import ChalkKit

/// Chrome (ChalkKit `ThemePalette`, which ChalkPalette and the AppKit glue wrap) and editor
/// (chalk-theme.css) must be indistinguishable in every theme: shared hexes are asserted per theme
/// and appearance, so drift fails tests.
final class PaletteParityTests: XCTestCase {
    /// (palette field, --ink-* variable) pairs shared across the seam.
    private let pairs: [(field: KeyPath<ThemePalette, HexPair>, name: String, css: String)] = [
        (\.editorBackground, "editorBackground", "--ink-bg-editor"),
        (\.accent, "accent", "--ink-accent"),
        (\.textPrimary, "textPrimary", "--ink-text-primary"),
        (\.textBody, "textBody", "--ink-text-body"),
        (\.textSecondary, "textSecondary", "--ink-text-secondary"),
        (\.textMuted, "textMuted", "--ink-text-muted"),
        (\.textFaint, "textFaint", "--ink-text-faint"),
        (\.textGhost, "textGhost", "--ink-text-ghost"),
    ]

    // MARK: - File loading

    /// `#filePath` is .../mac/ChalkKit/Tests/ChalkKitTests/PaletteParityTests.swift;
    /// five `deletingLastPathComponent()` hops (file -> ChalkKitTests ->
    /// Tests -> ChalkKit -> ios -> repo root) reach the repo root.
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func css() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent("web/src/chalk-theme.css"))
    }

    // MARK: - Block lookup

    /// The selector of a theme's block for one appearance. Ink is the bare default.
    private func selector(_ theme: ChalkTheme, dark: Bool) -> String {
        switch (theme, dark) {
        case (.ink, true): return ":root"
        case (.ink, false): return #":root[data-theme="light"]"#
        case (_, true): return #":root[data-palette="\#(theme.rawValue)"]:not([data-theme="light"])"#
        case (_, false): return #":root[data-palette="\#(theme.rawValue)"][data-theme="light"]"#
        }
    }

    /// The body of the rule whose selector is exactly `selector` (at the start of a line).
    private func block(_ selector: String, in css: String) throws -> String {
        let opener = "\n\(selector) {\n"
        let start = try XCTUnwrap(css.range(of: opener), "no `\(selector)` block in chalk-theme.css")
        let end = try XCTUnwrap(css.range(of: "\n}", range: start.upperBound..<css.endIndex))
        return String(css[start.upperBound..<end.lowerBound])
    }

    private func hex(_ variable: String, in block: String) -> Int? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: variable)):\\s*#([0-9a-fA-F]{6});"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: block, range: NSRange(block.startIndex..<block.endIndex, in: block)),
              let range = Range(match.range(at: 1), in: block)
        else { return nil }
        return Int(block[range], radix: 16)
    }

    /// Every custom property a block declares.
    private func properties(in block: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: "(--[A-Za-z0-9-]+):")
        let range = NSRange(block.startIndex..<block.endIndex, in: block)
        return Set(regex.matches(in: block, range: range).compactMap {
            Range($0.range(at: 1), in: block).map { String(block[$0]) }
        })
    }

    // MARK: - Tests

    func testSharedHexesMatchInEveryThemeAndAppearance() throws {
        let css = try css()
        for theme in ChalkTheme.allCases {
            for dark in [true, false] {
                let body = try block(selector(theme, dark: dark), in: css)
                for pair in pairs {
                    XCTAssertEqual(
                        hex(pair.css, in: body), theme.palette[keyPath: pair.field].hex(dark: dark),
                        "\(theme) \(dark ? "dark" : "light"): \(pair.name) drifted from \(pair.css)")
                }
            }
        }
    }

    /// The chrome background's dark value is shared with the page's widget chrome (the suggest
    /// box); the light side is native-only.
    func testChromeBackgroundDarkIsTheSuggestWidget() throws {
        let css = try css()
        for theme in ChalkTheme.allCases {
            let body = try block(selector(theme, dark: true), in: css)
            XCTAssertEqual(
                hex("--vscode-editorSuggestWidget-background", in: body),
                theme.palette.chromeBackground.dark,
                "\(theme): chromeBackground dark drifted from --vscode-editorSuggestWidget-background")
        }
    }

    /// A theme block that forgets a property inherits Ink's value for it in dark (bare :root) and
    /// Ink light's in light, a stray colour nobody sees in review. Ink light declares the full
    /// colour set, so every other block must declare at least that.
    func testEveryThemeBlockDeclaresTheWholeColourSet() throws {
        let css = try css()
        let required = properties(in: try block(selector(.ink, dark: false), in: css))
        XCTAssertGreaterThan(required.count, 40, "Ink light should carry the full colour set")
        for theme in ChalkTheme.allCases where theme != .ink {
            for dark in [true, false] {
                let missing = required.subtracting(
                    properties(in: try block(selector(theme, dark: dark), in: css)))
                XCTAssertEqual(missing, [], "\(theme) \(dark ? "dark" : "light") leaks Ink for \(missing.sorted())")
            }
        }
    }
}
