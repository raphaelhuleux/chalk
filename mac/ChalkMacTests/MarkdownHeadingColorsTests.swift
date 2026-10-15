import XCTest
import ChalkKit
@testable import ChalkMac

/// Settings → Editor → "Color Markdown Headings": the preference and the push
/// that carries it to an open editor.
///
/// The colors themselves are ChalkKit's (`MarkdownHeadingPaletteTests`). What
/// is native-only, and asserted here, is the pairing rule: the palette is a
/// function of the RESOLVED appearance, so it has to travel the same route as
/// `setAppearance` — a flip that forgets to re-push leaves Frappé's dark row on
/// cream paper.
///
/// `Preferences` reads `UserDefaults.standard` with no injectable suite, so the
/// raw key is snapshotted in `setUp` and restored in `tearDown` (NOT in a
/// `defer`, which an interrupted run skips — see PreferencePollutionGuardTests).
@MainActor
final class MarkdownHeadingColorsTests: XCTestCase {
    private let key = "chalk.colorHeadings"
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    // MARK: - The preference

    /// Off on a fresh install: existing documents must look exactly as they did
    /// before this feature shipped until someone asks for color.
    func testDefaultsOff() {
        XCTAssertFalse(Preferences.colorHeadings)
    }

    func testPersistsBothWays() {
        Preferences.colorHeadings = true
        XCTAssertTrue(Preferences.colorHeadings)
        Preferences.colorHeadings = false
        XCTAssertFalse(Preferences.colorHeadings)
    }

    // MARK: - The push

    /// A real container with a real surface: `Tab` builds its own
    /// `WebEditorSurface`, so there is no fake to inject here. The surface's
    /// DEBUG hook reports what the host last told it to show.
    private func hostedContainer() throws -> (NSWindow, EditorContainerViewController, URL) {
        
        let window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let container = EditorContainerViewController()
        container.hostOwnsAppearanceTransitions = true
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-heading-colors-\(UUID().uuidString).md")
        try Data("# one\n## two\n".utf8).write(to: file)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: file)
            Task { @MainActor in
                window.isHidden = true
                window.rootViewController = nil
            }
        }
        return (window, container, file)
    }

    private func host(_ window: NSWindow,
                      _ container: EditorContainerViewController,
                      dark: Bool) {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.rootViewController = container
        window.isHidden = false
        container.loadViewIfNeeded()
        window.layoutIfNeeded()
    }

    /// A tab opened with the toggle ON gets the row for the theme it is
    /// actually showing.
    func testAnOpenTabGetsThePaletteForItsAppearance() throws {
        Preferences.colorHeadings = true
        let (window, container, file) = try hostedContainer()
        host(window, container, dark: true)
        container.open(url: file)
        container.pushAppearance(dark: true, theme: .ink)

        XCTAssertEqual(container.activeSurfaceHeadingColorsForTesting,
                       MarkdownHeadingPalette.frappe)
    }

    /// The bug this pairing exists to prevent: an appearance flip that carries
    /// the theme but not the palette leaves dark-theme hues on light paper.
    func testAnAppearanceFlipCarriesTheOtherRow() throws {
        Preferences.colorHeadings = true
        let (window, container, file) = try hostedContainer()
        host(window, container, dark: true)
        container.open(url: file)
        container.pushAppearance(dark: true, theme: .ink)
        XCTAssertEqual(container.activeSurfaceHeadingColorsForTesting,
                       MarkdownHeadingPalette.frappe)

        container.pushAppearance(dark: false, theme: .ink)
        XCTAssertEqual(container.activeSurfaceHeadingColorsForTesting,
                       MarkdownHeadingPalette.latte,
                       "the palette must follow the theme it was pushed with")
    }

    /// Off pushes an EMPTY payload rather than skipping the send: skipping
    /// would leave the last colored row stuck on the page after the user turns
    /// the toggle back off.
    func testTurningItOffPushesAnEmptyPayload() throws {
        Preferences.colorHeadings = true
        let (window, container, file) = try hostedContainer()
        host(window, container, dark: true)
        container.open(url: file)
        container.pushAppearance(dark: true, theme: .ink)
        XCTAssertEqual(container.activeSurfaceHeadingColorsForTesting,
                       MarkdownHeadingPalette.frappe)

        Preferences.colorHeadings = false
        container.applyHeadingColors()

        XCTAssertEqual(container.activeSurfaceHeadingColorsForTesting, HeadingColors(),
                       "off must clear the vars, not stop sending")
    }

    /// A tab opened while the toggle is off must not be seeded with color.
    func testATabOpenedWithTheToggleOffIsNotColored() throws {
        Preferences.colorHeadings = false
        let (window, container, file) = try hostedContainer()
        host(window, container, dark: true)
        container.open(url: file)
        container.pushAppearance(dark: true, theme: .ink)

        XCTAssertEqual(container.activeSurfaceHeadingColorsForTesting, HeadingColors())
    }
}
