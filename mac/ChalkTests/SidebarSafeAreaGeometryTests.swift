import XCTest
import ChalkKit
@testable import Chalk

/// The Library's rows must not move when the titlebar comes and goes
/// (2026-08-18).
///
/// On Mac the titlebar reaches the Library's column as its safe-area top, and
/// full screen takes it away: the glue hides the toolbar going in and restores
/// it coming out. Every UIKit mechanism that reads the safe area then moved the
/// list — section insets (`contentInsetsReference` defaults to `.safeArea`),
/// cell layout margins (the first Location header measured 85pt with the band
/// against 62pt without), and finally `UICollectionView`'s own anchor restore
/// (`_restoreOrAdjustContentOffsetIfNecessaryWithInsets:`, stack-verified on
/// the running Mac app), which re-scrolled the list by exactly one titlebar.
/// The Library was left scrolled and the first Location rode up under the
/// traffic lights, so the gap changed across a windowed → full screen →
/// windowed round trip (owner report). Measured live: contentOffset 38 → 61,
/// first header y 28 → 6, while the panel, the column, the titlebar and the
/// lights all stayed byte-identical.
///
/// The rule: the list is safe-area-free, and the band is reserved through the
/// tree's TOP CONSTRAINT — the collection view's frame, which its scroll
/// content never sees.
@MainActor
final class SidebarSafeAreaGeometryTests: XCTestCase {
    /// Enough rows that the list is scrollable — a list shorter than its
    /// column cannot drift, which is why this only showed up with a populated
    /// Library.
    private func tempTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-safearea-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for n in 1...60 {
            try Data("# \(n)\n".utf8).write(
                to: root.appendingPathComponent(String(format: "%03d-note.md", n)))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeSidebar(root: URL) -> (SidebarViewController, UIWindow) {
        let sidebar = SidebarViewController()
        sidebar.locationsProvider = { [Location(id: "test", name: "Test", url: root)] }
        let window = UIWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        window.rootViewController = sidebar
        window.isHidden = false
        sidebar.loadViewIfNeeded()
        sidebar.reload()
        settle(sidebar, window)
        return (sidebar, window)
    }

    private func settle(_ sidebar: SidebarViewController, _ window: UIWindow) {
        window.layoutIfNeeded()
        sidebar.collectionViewForTesting.layoutIfNeeded()
    }

    /// Stand in for the host: the Library asks `treeTopProvider` at every
    /// layout pass, so answer with `y` and ask for a pass.
    private func hostTreeTop(_ y: CGFloat, on sidebar: SidebarViewController) {
        sidebar.treeTopProvider = { y }
        sidebar.view.setNeedsLayout()
    }

    /// One shell transition as Catalyst delivers it: the window resizes AND the
    /// titlebar's safe area appears or vanishes in the same pass. The resize is
    /// what makes a collection view re-anchor, so a safe-area change on its own
    /// does not reproduce the drift.
    private func apply(
        band: CGFloat, height: CGFloat,
        to sidebar: SidebarViewController, _ window: UIWindow
    ) {
        window.frame = CGRect(x: 0, y: 0, width: window.frame.width, height: height)
        sidebar.additionalSafeAreaInsets.top = band
        settle(sidebar, window)
    }

    /// The titlebar band, as it reaches a Catalyst scene.
    private let titlebarBand: CGFloat = 52

    // MARK: - The rule

    /// Nothing inside the panel may read the safe area: the panel is
    /// hand-pinned to the window's top edge, and the band is reserved through
    /// the tree's frame instead.
    func testTheListIsSafeAreaFree() throws {
        let (sidebar, window) = makeSidebar(root: try tempTree())
        sidebar.additionalSafeAreaInsets.top = titlebarBand
        settle(sidebar, window)

        XCTAssertEqual(sidebar.collectionViewForTesting.safeAreaInsets, .zero,
                       "a safe area inside the panel is what moved the rows")
    }

    /// The list starts on the line the HOST hands it (`treeTopProvider`), the
    /// chrome floor. The Library takes the number as given and only converts it
    /// into its panel's coordinates, so this drives the seam with values of its
    /// own rather than re-deriving the datum.
    func testTheListStartsWhereTheHostSaysItDoes() throws {
        let (sidebar, window) = makeSidebar(root: try tempTree())
        func firstHeaderTopInWindow() throws -> CGFloat {
            let frame = try XCTUnwrap(sidebar.firstHeaderFrameForTesting)
            return sidebar.view.convert(frame, to: window).minY
        }

        for top in [CGFloat(52), 70, 120] {
            hostTreeTop(top, on: sidebar)
            settle(sidebar, window)
            let header = try firstHeaderTopInWindow()
            XCTAssertGreaterThanOrEqual(
                header, top - 1,
                "a header above the line is a header sliding under the chrome")
            XCTAssertLessThan(
                header, top + ChalkMetrics.sidebarRowHeight,
                "on the line, within the list's own residual padding — not a row lower")
        }
    }

    /// The round trip in the report: whatever the chrome does, the clearance
    /// must land back where it started.
    func testFullScreenRoundTripRestoresTheClearance() throws {
        let (sidebar, window) = makeSidebar(root: try tempTree())
        hostTreeTop(67, on: sidebar)
        settle(sidebar, window)
        let windowed = sidebar.treeTopClearance()

        hostTreeTop(0, on: sidebar) // full screen: the glue hides the titlebar
        settle(sidebar, window)
        hostTreeTop(67, on: sidebar)
        settle(sidebar, window)

        XCTAssertEqual(sidebar.treeTopClearance(), windowed, accuracy: 0.5)
    }

    /// The clearance is written from inside a layout pass, so it has to reach a
    /// fixed point: a value that moves the panel, which re-derives the value,
    /// is how a Library freezes the app.
    func testTheClearanceSettlesInsteadOfChasingItself() throws {
        let (sidebar, window) = makeSidebar(root: try tempTree())
        hostTreeTop(70, on: sidebar)
        settle(sidebar, window)
        let settled = sidebar.treeTopClearance()

        for pass in 1...5 {
            sidebar.view.setNeedsLayout()
            settle(sidebar, window)
            XCTAssertEqual(sidebar.treeTopClearance(), settled, accuracy: 0.5,
                           "layout pass \(pass) moved the tree again")
        }
    }

    // MARK: - The symptom

    /// The Library must not scroll itself when the shell changes around it.
    func testTitlebarBandComingAndGoingLeavesTheListAtRest() throws {
        let (sidebar, window) = makeSidebar(root: try tempTree())
        let collection = sidebar.collectionViewForTesting
        let resting = -collection.adjustedContentInset.top
        XCTAssertEqual(collection.contentOffset.y, resting, accuracy: 0.5,
                       "precondition: a freshly loaded Library starts at the top")

        apply(band: titlebarBand, height: 600, to: sidebar, window)
        XCTAssertEqual(collection.contentOffset.y, resting, accuracy: 0.5,
                       "the titlebar's safe area must not scroll the Library")

        apply(band: 0, height: 1000, to: sidebar, window) // full screen
        XCTAssertEqual(collection.contentOffset.y, resting, accuracy: 0.5)

        apply(band: titlebarBand, height: 600, to: sidebar, window) // and back
        XCTAssertEqual(collection.contentOffset.y, resting, accuracy: 0.5,
                       "a full-screen round trip must leave the Library where it was")
    }

    /// The first Location header keeps its place in the CONTENT across the
    /// round trip; only the tree's frame moves with the band.
    func testFirstLocationKeepsItsPlaceInTheContent() throws {
        let (sidebar, window) = makeSidebar(root: try tempTree())
        func firstHeaderInContent() throws -> CGRect {
            let headers = sidebar.collectionViewForTesting.visibleSupplementaryViews(
                ofKind: UICollectionView.elementKindSectionHeader)
            return try XCTUnwrap(headers.map(\.frame).min { $0.minY < $1.minY })
        }

        apply(band: titlebarBand, height: 600, to: sidebar, window)
        let before = try firstHeaderInContent()

        apply(band: 0, height: 1000, to: sidebar, window)
        apply(band: titlebarBand, height: 600, to: sidebar, window)

        XCTAssertEqual(try firstHeaderInContent().minY, before.minY, accuracy: 0.5,
                       "the header's position in the content must survive the round trip")
    }
}
