import XCTest
import ChalkKit
@testable import Chalk

/// What the root's view carries once it exists. The Catalyst root had to
/// avoid loading its view inside init (`RootInitOrderTests`); the AppKit root
/// builds its whole tree in `loadView` from properties that exist before
/// `super.init`, and pins the appearance and a restored session's sidebar on
/// the view during init on purpose, so that rule has no AppKit counterpart.
@MainActor
final class RootViewWiringTests: XCTestCase {
    /// The chrome's pointer tracker (the band's auto-hide reveal) is part of
    /// the view, installed when it loads.
    func testTheChromePointerTrackerIsInstalledWithTheView() {
        let root = RootSplitViewController(initialContent: .openEmpty)
        root.loadViewIfNeeded()
        XCTAssertTrue(root.view.subviews.contains { $0 is PointerBandTracker })
    }
}
