import XCTest
import ChalkKit
@testable import Chalk

/// Where the Library's list starts, through the transitions that move it.
///
/// The header sits on the chrome floor (the system titlebar spans the whole
/// window, so the list has nowhere else to start). The number arrives from the
/// host, the panel is flush, and the list layout keeps a padding of its own
/// above the first header that has to be trimmed — three moving parts, and the
/// transition matrix caught them disagreeing after a sidebar round trip (the
/// list landed 22pt high, one list-padding off).
@MainActor
final class LibraryListStartTests: XCTestCase {
    private var window: UIWindow!
    private var root: RootSplitViewController!

    override func setUp() {
        super.setUp()
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first!
        window = UIWindow(windowScene: scene)
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private var listStart: CGFloat? {
        let sidebar = root.sidebarForTesting
        guard sidebar.isViewLoaded else { return nil }
        return sidebar.firstHeaderFrameForTesting
            .map { root.view.convert($0, from: sidebar.view).minY }
    }

    private var trim: CGFloat { root.sidebarForTesting.collectionViewForTesting.contentInset.top }
    private var offset: CGFloat { root.sidebarForTesting.collectionViewForTesting.contentOffset.y }

    /// Open the Library the way the shell does, and settle. A root that has
    /// never shown its primary column reports an unlaid panel, which is not a
    /// state worth comparing against.
    private func openLibrary() {
        root.applyTransitionForTesting(.sidebar(true))
        settle()
    }

    /// MAC: the list starts ON the chrome floor. The band there is the system
    /// titlebar spanning the whole window, so the Library has nowhere to go
    /// but below it (`libraryListStartsAtTheChromeFloor`).
    func testTheFirstAreaHeaderSitsOnTheChromeFloor() throws {
        openLibrary()
        let reserve = root.chromeReserveForTesting
        XCTAssertGreaterThan(reserve, 0, "precondition: the chrome reserves something")
        XCTAssertEqual(try XCTUnwrap(listStart), reserve, accuracy: 1.5,
                       "the two columns begin their content together "
                       + "(trim=\(trim) offset=\(offset))")
    }

    /// A sidebar hide/show round trip must hand the list back where a fresh
    /// layout would put it — the same rule the transition matrix enforces over
    /// every path, stated here where the numbers are readable.
    func testASidebarRoundTripLeavesTheListWhereItStarted() throws {
        openLibrary()
        let fresh = try XCTUnwrap(listStart)
        let freshTrim = trim

        root.applyTransitionForTesting(.sidebar(false))
        settle()
        root.applyTransitionForTesting(.sidebar(true))
        settle()

        XCTAssertEqual(trim, freshTrim, accuracy: 0.5,
                       "the measured list trim must not accumulate across a round trip "
                       + "(trim=\(trim) offset=\(offset))")
        XCTAssertEqual(try XCTUnwrap(listStart), fresh, accuracy: 1.0,
                       "the list starts where it started (trim=\(trim) offset=\(offset))")
    }

    /// The same, twice, because an accumulating trim shows up on the second
    /// lap even when the first one looks clean.
    func testTwoRoundTripsDoNotDriftTheList() throws {
        openLibrary()
        let fresh = try XCTUnwrap(listStart)
        for lap in 1...2 {
            root.applyTransitionForTesting(.sidebar(false))
            settle()
            root.applyTransitionForTesting(.sidebar(true))
            settle()
            XCTAssertEqual(try XCTUnwrap(listStart), fresh, accuracy: 1.0,
                           "lap \(lap): trim=\(trim) offset=\(offset)")
        }
    }
}

