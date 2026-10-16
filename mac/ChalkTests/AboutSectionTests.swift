import XCTest
@testable import Chalk
import ChalkKit

/// The About section is where a user goes when something is wrong, so it has
/// to carry the three things they need: which build this is, how to reach a
/// person, and what the app does with their data.
@MainActor
final class AboutSectionTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "chalk-about-\(UUID().uuidString)")
    }

    private func settings() -> GeneralSettingsViewController {
        let controller = GeneralSettingsViewController()
        controller.alphaSessionForTesting = AlphaSession(
            build: BuildInfo(infoDictionary: [
                "CFBundleShortVersionString": "1.0.0",
                "CFBundleVersion": "42",
                "CHALKGitCommit": "deadbee",
            ]), defaults: defaults)
        return controller
    }

    private let aboutSection = GeneralSettingsViewController.sectionTitles.firstIndex(of: "About")!

    private func aboutTitles(_ controller: GeneralSettingsViewController) -> [String] {
        controller.rowTitlesForTesting(section: aboutSection)
    }

    func testTheAboutRows() {
        XCTAssertEqual(aboutTitles(settings()),
                       ["Version", "Report a Problem", "Privacy", "Acknowledgements"])
    }

    /// The version row is what a screenshot has to answer with. Without the
    /// commit, "which build is this?" costs a round trip.
    func testTheVersionRowNamesTheCommit() {
        let detail = settings().rowDetailForTesting(section: aboutSection, row: 0)
        XCTAssertTrue(detail.contains("1.0.0"))
        XCTAssertTrue(detail.contains("42"))
        XCTAssertTrue(detail.contains("deadbee"))
    }

    /// Every row that leads somewhere must be reachable. A disclosure arrow on
    /// a row that does nothing is worse than no row.
    func testEveryDisclosureRowHasADestination() {
        let controller = settings()
        for row in 0..<aboutTitles(controller).count {
            let hasArrow = controller.rowHasDisclosureForTesting(section: aboutSection, row: row)
            let opens = controller.destination(section: aboutSection, row: row) != nil
            XCTAssertEqual(hasArrow, opens,
                           "row \(row) (\(aboutTitles(controller)[row])) shows an arrow "
                           + "but leads nowhere, or leads somewhere without saying so")
        }
    }

    /// The Acknowledgements screen carries the bundled notices.
    func testAcknowledgementsReadTheBundledNotices() throws {
        let screen = try XCTUnwrap(settings().destination(section: aboutSection, row: 3) as? AcknowledgementsViewController)
        XCTAssertFalse(screen.textForTesting.isEmpty)
        XCTAssertFalse(screen.textForTesting.contains("unavailable in this build"),
                       "THIRD-PARTY-NOTICES must ship in the app bundle")
    }
}
