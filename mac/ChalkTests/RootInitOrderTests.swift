import XCTest
@testable import Chalk

/// Building a root must not load its view. A `view` touch in init runs
/// viewDidLoad in the middle of init, before the rest of init has wired the
/// strip, the pill and the Library.
@MainActor
final class RootInitOrderTests: XCTestCase {
    func testInitDoesNotLoadTheView() {
        let empty = RootSplitViewController(initialContent: .openEmpty)
        XCTAssertFalse(empty.isViewLoaded)
        // A first tab runs the strip update path (on Mac it asks the host
        // whether its window is key).
        let welcome = RootSplitViewController(initialContent: .openWelcome)
        XCTAssertFalse(welcome.isViewLoaded)
    }

    func testTheChromeHoverRecognizerIsInstalledWithTheView() {
        let root = RootSplitViewController(initialContent: .openEmpty)
        root.loadViewIfNeeded()
        XCTAssertTrue(root.view.gestureRecognizers?.contains { $0 is UIHoverGestureRecognizer } == true)
    }
}
