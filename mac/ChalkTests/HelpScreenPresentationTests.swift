import XCTest
import ChalkKit
@testable import Chalk

/// Report a Problem and Privacy are sheets like the asset preview, so they go
/// through the same presentation path: the app's forced appearance (a sheet
/// window would otherwise follow the system's), focus back to the editor on
/// dismissal, and no open palette left underneath.
@MainActor
final class HelpScreenPresentationTests: XCTestCase {
    private var incomingTheme: ThemePreference!
    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        incomingTheme = Preferences.themePreference // real app defaults: restore in tearDown
    }

    override func tearDown() {
        Preferences.themePreference = incomingTheme
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet) }
        dismantleHostedSidebar(window)
        window = nil
        super.tearDown()
    }

    private func hostedRoot() -> RootSplitViewController {
        let root = RootSplitViewController(initialContent: .openEmpty)
        let window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1180, height: 820))
        window.rootViewController = root
        window.isHidden = false
        self.window = window
        root.view.layoutSubtreeIfNeeded()
        return root
    }

    func testPrivacyIsPresentedLikeTheOtherSheets() throws {
        Preferences.themePreference = .light
        let root = hostedRoot()
        root.cmdQuickOpen()
        XCTAssertTrue(root.isQuickOpenVisibleForTesting)

        root.cmdPrivacy()

        let sheet = try XCTUnwrap(window?.attachedSheet, "the screen is a sheet on the window")
        let host = try XCTUnwrap(sheet.contentViewController as? HelpSheetHostViewController)
        XCTAssertTrue(host.screen is PrivacyViewController)
        XCTAssertEqual(sheet.appearance?.name, .aqua, "the sheet carries the app's forced appearance")
        XCTAssertFalse(root.isQuickOpenVisibleForTesting, "the palette does not stay under the sheet")
        XCTAssertEqual(sheet.title, "Privacy")
    }

    func testReportAProblemIsASheetToo() throws {
        let root = hostedRoot()
        root.cmdReportProblem()
        let sheet = try XCTUnwrap(window?.attachedSheet)
        let host = try XCTUnwrap(sheet.contentViewController as? HelpSheetHostViewController)
        XCTAssertTrue(host.screen is ReportProblemViewController)
        // Done ends the sheet.
        host.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertNil(window?.attachedSheet)
    }

    /// A theme change made while a sheet is up reaches the sheet.
    func testAThemeChangeRepinsTheOpenSheet() throws {
        Preferences.themePreference = .light
        let root = hostedRoot()
        root.cmdPrivacy()
        let sheet = try XCTUnwrap(window?.attachedSheet)
        XCTAssertEqual(sheet.appearance?.name, .aqua)
        Preferences.themePreference = .dark
        root.applyThemePreference()
        XCTAssertEqual(sheet.appearance?.name, .darkAqua)
    }
}
