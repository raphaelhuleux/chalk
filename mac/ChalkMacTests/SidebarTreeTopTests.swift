import XCTest
import ChalkKit
@testable import ChalkMac

/// The Library's rows must not move when the titlebar comes and goes
/// (2026-08-18, Catalyst: every mechanism that read the safe area moved the
/// list across a full-screen round trip, and the collection view re-scrolled
/// by one titlebar).
///
/// The rule: the band is reserved through the tree's TOP CONSTRAINT, the
/// scroll view's frame, which its scroll content never sees. The host hands
/// the line down (`treeTopProvider`); the Library only converts it.
@MainActor
final class SidebarTreeTopTests: XCTestCase {
    /// Enough rows that the list is scrollable: a list shorter than its column
    /// cannot drift, which is why this only showed up with a populated Library.
    private func tempTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-treetop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for n in 1...60 {
            try Data("# \(n)\n".utf8).write(
                to: root.appendingPathComponent(String(format: "%03d-note.md", n)))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private var window: NSWindow?

    override func tearDown() {
        dismantleHostedSidebar(window)
        window = nil
        super.tearDown()
    }

    private func makeSidebar(root: URL) -> (SidebarViewController, NSWindow) {
        let made = makeHostedSidebar(locations: [Location(id: "test", name: "Test", url: root)])
        window = made.1
        return made
    }

    /// Stand in for the host: the Library asks `treeTopProvider` at every
    /// layout pass, so answer with `y` and ask for a pass.
    private func hostTreeTop(_ y: CGFloat, on sidebar: SidebarViewController) {
        sidebar.treeTopProvider = { y }
        sidebar.view.needsLayout = true
    }

    /// One shell transition: the window resizes AND the chrome line moves in
    /// the same pass. The resize is what makes a scroll view re-anchor.
    private func apply(treeTop: CGFloat, height: CGFloat,
                       to sidebar: SidebarViewController, _ window: NSWindow) {
        window.frame = CGRect(x: 0, y: 0, width: window.frame.width, height: height)
        hostTreeTop(treeTop, on: sidebar)
        settleSidebar(sidebar, window)
    }

    /// The titlebar band, as the shell reserves it.
    private let titlebarBand: CGFloat = 52

    // MARK: - The rule

    /// Nothing inside the panel may move the content: the band is reserved
    /// through the scroll view's frame, and the list's content insets stay at
    /// zero on top.
    func testTheListReservesTheBandThroughItsFrameNotItsContent() throws {
        let (sidebar, _) = makeSidebar(root: try tempTree())
        XCTAssertFalse(sidebar.scrollView.automaticallyAdjustsContentInsets,
                       "a system-managed content inset is what moved the rows")
        XCTAssertEqual(sidebar.scrollView.contentInsets.top, 0)
    }

    /// The list starts on the line the HOST hands it, the chrome floor.
    func testTheListStartsWhereTheHostSaysItDoes() throws {
        let (sidebar, window) = makeSidebar(root: try tempTree())
        func firstHeaderTopInWindow() throws -> CGFloat {
            let frame = try XCTUnwrap(sidebar.firstHeaderFrameForTesting)
            return (window.contentView?.convert(frame, from: sidebar.view).minY) ?? -1
        }

        for top in [CGFloat(52), 70, 120] {
            hostTreeTop(top, on: sidebar)
            settleSidebar(sidebar, window)
            let header = try firstHeaderTopInWindow()
            XCTAssertGreaterThanOrEqual(
                header, top - 1,
                "a header above the line is a header sliding under the chrome")
            XCTAssertLessThan(
                header, top + ChalkMetrics.sidebarRowHeight,
                "on the line, within the list's own residual padding, not a row lower")
        }
    }

    /// The round trip in the report: whatever the chrome does, the clearance
    /// must land back where it started.
    func testFullScreenRoundTripRestoresTheClearance() throws {
        let (sidebar, window) = makeSidebar(root: try tempTree())
        hostTreeTop(67, on: sidebar)
        settleSidebar(sidebar, window)
        let windowed = sidebar.treeTopClearance()

        hostTreeTop(0, on: sidebar) // full screen: no titlebar
        settleSidebar(sidebar, window)
        hostTreeTop(67, on: sidebar)
        settleSidebar(sidebar, window)

        XCTAssertEqual(sidebar.treeTopClearance(), windowed, accuracy: 0.5)
    }

    /// The clearance is written from inside a layout pass, so it has to reach
    /// a fixed point.
    func testTheClearanceSettlesInsteadOfChasingItself() throws {
        let (sidebar, window) = makeSidebar(root: try tempTree())
        hostTreeTop(70, on: sidebar)
        settleSidebar(sidebar, window)
        let settled = sidebar.treeTopClearance()

        for pass in 1...5 {
            sidebar.view.needsLayout = true
            settleSidebar(sidebar, window)
            XCTAssertEqual(sidebar.treeTopClearance(), settled, accuracy: 0.5,
                           "layout pass \(pass) moved the tree again")
        }
    }

    // MARK: - The symptom

    /// The Library must not scroll itself when the shell changes around it.
    func testTitlebarBandComingAndGoingLeavesTheListAtRest() throws {
        let (sidebar, window) = makeSidebar(root: try tempTree())
        XCTAssertEqual(sidebar.libraryScrollOffsetForTesting, 0, accuracy: 0.5,
                       "precondition: a freshly loaded Library starts at the top")

        apply(treeTop: titlebarBand, height: 600, to: sidebar, window)
        XCTAssertEqual(sidebar.libraryScrollOffsetForTesting, 0, accuracy: 0.5,
                       "the titlebar's reserve must not scroll the Library")

        apply(treeTop: 0, height: 1000, to: sidebar, window) // full screen
        XCTAssertEqual(sidebar.libraryScrollOffsetForTesting, 0, accuracy: 0.5)

        apply(treeTop: titlebarBand, height: 600, to: sidebar, window) // and back
        XCTAssertEqual(sidebar.libraryScrollOffsetForTesting, 0, accuracy: 0.5,
                       "a full-screen round trip must leave the Library where it was")
    }

    /// The first Location header keeps its place in the CONTENT across the
    /// round trip; only the tree's frame moves with the band.
    func testFirstLocationKeepsItsPlaceInTheContent() throws {
        let (sidebar, window) = makeSidebar(root: try tempTree())
        apply(treeTop: titlebarBand, height: 600, to: sidebar, window)
        let before = try XCTUnwrap(sidebar.headerRectForTesting(section: 0))

        apply(treeTop: 0, height: 1000, to: sidebar, window)
        apply(treeTop: titlebarBand, height: 600, to: sidebar, window)

        XCTAssertEqual(try XCTUnwrap(sidebar.headerRectForTesting(section: 0)).minY, before.minY, accuracy: 0.5,
                       "the header's position in the content must survive the round trip")
    }

    /// A reader's scroll position survives the same round trip.
    func testAScrolledListStaysScrolled() throws {
        let (sidebar, window) = makeSidebar(root: try tempTree())
        apply(treeTop: titlebarBand, height: 600, to: sidebar, window)
        sidebar.setLibraryScrollOffsetForTesting(120)
        XCTAssertEqual(sidebar.libraryScrollOffsetForTesting, 120, accuracy: 1,
                       "the seed must actually scroll, or the round trip proves nothing")
        apply(treeTop: 0, height: 1000, to: sidebar, window)
        apply(treeTop: titlebarBand, height: 600, to: sidebar, window)
        XCTAssertEqual(sidebar.libraryScrollOffsetForTesting, 120, accuracy: 1)
    }
}
