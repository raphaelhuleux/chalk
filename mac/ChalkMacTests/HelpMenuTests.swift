import XCTest
import ChalkKit
@testable import ChalkMac

/// What the Help menu offers, read through `MainMenu.helpMenuItems()`, which
/// `MainMenu.build()` installs.
@MainActor
final class HelpMenuTests: XCTestCase {
    func testTheMenuOffersReportAndPrivacy() {
        XCTAssertEqual(MainMenu.helpMenuItems().map(\.title),
                       ["Report a Problem\u{2026}", "Privacy"])
    }

    /// The actions are what the items are for; a title that no longer routes
    /// anywhere is a menu item that does nothing.
    func testEveryItemRoutesToItsCommand() {
        XCTAssertEqual(MainMenu.helpMenuItems().map(\.action), [
            #selector(RootSplitViewController.cmdReportProblem(_:)),
            #selector(RootSplitViewController.cmdPrivacy(_:)),
        ])
    }

    /// The built menu carries them under Help, and Settings under the app menu on ⌘,.
    func testTheBuiltMenuCarriesHelpAndSettings() throws {
        let main = MainMenu.build()
        let help = try XCTUnwrap(main.items.last?.submenu)
        XCTAssertEqual(help.title, "Help")
        XCTAssertEqual(help.items.map(\.title), ["Report a Problem\u{2026}", "Privacy"])
        let app = try XCTUnwrap(main.items.first?.submenu)
        let settings = try XCTUnwrap(app.items.first { $0.keyEquivalent == "," })
        XCTAssertEqual(settings.action, #selector(RootSplitViewController.cmdSettings(_:)))
    }
}
