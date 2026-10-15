import XCTest
import ChalkKit
@testable import Chalk

/// Report a Problem and Privacy are sheets like Settings and the asset
/// preview, so they go through the same presentation path: the app's forced
/// appearance (a Catalyst sheet otherwise follows the system's), focus back to
/// the editor on dismissal, and no open palette left underneath.
@MainActor
final class HelpScreenPresentationTests: XCTestCase {
    private var incomingTheme: ThemePreference!
    private var window: UIWindow?

    override func setUp() {
        super.setUp()
        incomingTheme = Preferences.themePreference // real app defaults: restore in tearDown
    }

    override func tearDown() {
        Preferences.themePreference = incomingTheme
        window?.rootViewController?.dismiss(animated: false)
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    private func hostedRoot() -> RootSplitViewController {
        let root = RootSplitViewController(initialContent: .openEmpty)
        let window = UIWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1180, height: 820))
        window.rootViewController = root
        window.isHidden = false
        self.window = window
        root.view.layoutIfNeeded()
        return root
    }

    func testPrivacyIsPresentedLikeTheOtherSheets() throws {
        Preferences.themePreference = .light
        let root = hostedRoot()
        root.cmdQuickOpen()
        XCTAssertTrue(root.isQuickOpenVisibleForTesting)

        root.cmdPrivacy()

        let nav = try XCTUnwrap(root.presentedViewController as? UINavigationController)
        XCTAssertTrue(nav.viewControllers.first is PrivacyViewController)
        XCTAssertEqual(nav.overrideUserInterfaceStyle, .light, "the sheet carries the app's forced appearance")
        XCTAssertTrue(nav.presentationController?.delegate === root,
                      "an interactive dismissal returns focus to the editor")
        XCTAssertFalse(root.isQuickOpenVisibleForTesting, "the palette does not stay under the sheet")
    }
}
