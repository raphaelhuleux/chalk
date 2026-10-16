import XCTest
import ChalkKit
@testable import Chalk

/// Settings is one window per app: ⌘, focuses it rather than stacking a
/// second, Esc and Done close it, it never shrinks under its floor, and it
/// carries the app's forced appearance.
@MainActor
final class SettingsWindowTests: XCTestCase {
    private var incomingTheme: ThemePreference!
    private var controller: SettingsWindowController?

    override func setUp() {
        super.setUp()
        incomingTheme = Preferences.themePreference
    }

    override func tearDown() {
        Preferences.themePreference = incomingTheme
        controller?.close()
        controller = nil
        super.tearDown()
    }

    func testTheWindowOpensAtItsDefaultSizeOverItsFloor() throws {
        let controller = SettingsWindowController()
        self.controller = controller
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.contentMinSize, ChalkMetrics.settingsMinWindowSize)
        XCTAssertGreaterThanOrEqual(window.contentView?.frame.width ?? 0, ChalkMetrics.settingsMinWindowSize.width)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.title, "Settings")
    }

    func testTheWindowCarriesTheForcedAppearance() throws {
        Preferences.themePreference = .light
        let controller = SettingsWindowController()
        self.controller = controller
        XCTAssertEqual(controller.window?.appearance?.name, .aqua)
        Preferences.themePreference = .dark
        controller.pinAppearance()
        XCTAssertEqual(controller.window?.appearance?.name, .darkAqua)
        Preferences.themePreference = .auto
        controller.pinAppearance()
        XCTAssertNil(controller.window?.appearance, "Auto follows the system")
    }

    func testDoneAndEscapeCloseTheWindow() throws {
        let controller = SettingsWindowController()
        self.controller = controller
        controller.showWindow(nil)
        XCTAssertTrue(try XCTUnwrap(controller.window).isVisible)
        controller.container.done()
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)

        controller.showWindow(nil)
        controller.container.cancelOperation(nil)
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)

        // ⌘, from inside the window means close too.
        controller.showWindow(nil)
        controller.container.cmdSettings(nil)
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
    }

    /// A General change reaches the roots the broadcast is given.
    func testTheBroadcastReachesEveryRoot() {
        let root = RootSplitViewController(initialContent: .openEmpty)
        root.loadViewIfNeeded()
        let before = Preferences.editorMeasure
        defer { Preferences.editorMeasure = before }
        Preferences.editorMeasure = 720
        SettingsBroadcast.applyGeneralSettings(roots: [root])
        XCTAssertEqual(root.editorMeasureForTesting ?? -1, 720, accuracy: 0.5)
    }
}
