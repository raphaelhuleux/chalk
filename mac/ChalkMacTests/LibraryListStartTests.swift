import XCTest
import ChalkKit
@testable import ChalkMac

/// Where the Library's list starts, through the transitions that move it.
///
/// The header sits on the chrome floor (the band spans the whole window, so
/// the list has nowhere else to start). The number arrives from the host and
/// the panel is flush; the transition matrix caught the two disagreeing after
/// a sidebar round trip on Catalyst.
@MainActor
final class LibraryListStartTests: XCTestCase {
    private var window: NSWindow!
    private var root: RootSplitViewController!

    override func setUp() {
        super.setUp()
        window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        root = RootSplitViewController()
        root.motionPolicyForTesting = .instant
        window.rootViewController = root
        window.isHidden = false
        // The list needs a Location header to measure; a detached window has none.
        root.setLibraryLocationsForTesting([SampleContent.documentsURL])
        settle()
    }

    override func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        root = nil
        super.tearDown()
    }

    private func settle() {
        for _ in 0..<4 {
            window.layoutIfNeeded()
            root.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private var listStart: CGFloat? {
        let sidebar = root.sidebarForTesting
        guard sidebar.isViewLoaded else { return nil }
        return sidebar.firstHeaderFrameForTesting
            .map { root.view.convert($0, from: sidebar.view).minY }
    }

    private var offset: CGFloat { root.libraryScrollOffsetForTesting }

    /// Open the Library the way the shell does, and settle.
    private func openLibrary() {
        root.applyTransitionForTesting(.sidebar(true))
        settle()
    }

    /// The list starts ON the chrome floor (`libraryListStartsAtTheChromeFloor`).
    func testTheFirstAreaHeaderSitsOnTheChromeFloor() throws {
        openLibrary()
        let reserve = root.libraryTreeTop
        XCTAssertGreaterThan(reserve, 0, "precondition: the chrome reserves something")
        XCTAssertEqual(try XCTUnwrap(listStart), reserve, accuracy: 1.5,
                       "the two columns begin their content together (offset=\(offset))")
    }

    /// A sidebar hide/show round trip must hand the list back where a fresh
    /// layout would put it.
    func testASidebarRoundTripLeavesTheListWhereItStarted() throws {
        openLibrary()
        let fresh = try XCTUnwrap(listStart)

        root.applyTransitionForTesting(.sidebar(false))
        settle()
        root.applyTransitionForTesting(.sidebar(true))
        settle()

        XCTAssertEqual(try XCTUnwrap(listStart), fresh, accuracy: 1.0,
                       "the list starts where it started (offset=\(offset))")
    }

    /// The same, twice, because a drift shows up on the second lap even when
    /// the first one looks clean.
    func testTwoRoundTripsDoNotDriftTheList() throws {
        openLibrary()
        let fresh = try XCTUnwrap(listStart)
        for lap in 1...2 {
            root.applyTransitionForTesting(.sidebar(false))
            settle()
            root.applyTransitionForTesting(.sidebar(true))
            settle()
            XCTAssertEqual(try XCTUnwrap(listStart), fresh, accuracy: 1.0,
                           "lap \(lap): offset=\(offset)")
        }
    }

    /// Full screen takes the titlebar away and the list follows the floor down;
    /// coming back it returns to the same line.
    func testAFullScreenRoundTripReturnsTheListToTheFloor() throws {
        openLibrary()
        let windowed = try XCTUnwrap(listStart)
        root.applyTransitionForTesting(.window(.fullscreen))
        settle()
        XCTAssertEqual(try XCTUnwrap(listStart), root.libraryTreeTop, accuracy: 1.5)
        root.applyTransitionForTesting(.window(.windowed))
        settle()
        XCTAssertEqual(try XCTUnwrap(listStart), windowed, accuracy: 1.0)
    }
}
