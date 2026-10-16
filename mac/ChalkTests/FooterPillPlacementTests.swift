import XCTest
import ChalkKit
@testable import Chalk

/// The floating utility pill's resting corner. Since Paper (2026-08-24) it is
/// ONE corner: the pill is the only home the chrome buttons have (the Library
/// holds files and nothing else), so it never hands off and it never hides.
///
/// What this pins: the pill rests `footerPillMargin` from the window's corner,
/// not above a bottom safe area. Window-hosted, because safe areas only
/// resolve in a window.
@MainActor
final class FooterPillPlacementTests: XCTestCase {
    private var window: NSWindow!
    private var root: RootSplitViewController!

    override func setUp() {
        super.setUp()
        
        window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        root = RootSplitViewController()
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
        root.view.layoutIfNeeded()
    }

    override func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        root = nil
        super.tearDown()
    }

    /// The pill rests `footerPillMargin` from the window's bottom-leading
    /// corner, ignoring any bottom safe area exactly as the flush Library panel
    /// does (Y-17).
    func testPillRestsInTheWindowsCornerNotAboveTheSafeArea() {
        let margin = ChalkMetrics.footerPillMargin
        // The failures this file exists to catch were 7pt and worse.
        let tolerance: CGFloat = 0.5
        let pill = root.footerPillFrameForTesting

        XCTAssertEqual(pill.maxY, root.view.bounds.height - margin, accuracy: tolerance,
                       "the pill rests in the corner, not above a safe area")
        XCTAssertEqual(pill.minX, margin, accuracy: tolerance)
    }

    /// It stands in every state now. Hiding it while the Library was a
    /// persistent column is what made it read as jumping.
    func testThePillStandsWhetherTheLibraryIsOpenOrNot() {
        XCTAssertFalse(root.footerPillFrameForTesting.isEmpty,
                       "the pill is the only home these buttons have")
        XCTAssertGreaterThan(root.footerPillFrameForTesting.width, 0)
    }
}
