import XCTest
@testable import Chalk

/// What the Help menu offers.
///
/// `UIMenuBuilder` cannot be constructed in a unit test, so the list lives in
/// `AppDelegate.helpMenuItems()` and this reads it. `buildHelpMenu` is then
/// only the plumbing that inserts it.
final class HelpMenuTests: XCTestCase {
    func testTheMenuOffersReportAndPrivacy() {
        XCTAssertEqual(AppDelegate.helpMenuItems().compactMap { $0.title },
                       ["Report a Problem\u{2026}", "Privacy"])
    }

    /// The actions are what the items are for; a title that no longer routes
    /// anywhere is a menu item that does nothing.
    func testEveryItemRoutesToItsCommand() {
        XCTAssertEqual(AppDelegate.helpMenuItems().map(\.action), [
            #selector(RootSplitViewController.cmdReportProblem),
            #selector(RootSplitViewController.cmdPrivacy),
        ])
    }
}
