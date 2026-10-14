import XCTest
import ChalkKit
@testable import Chalk

/// Full-height Library (2026-08-03): the panel's top rows sit under the Mac
/// titlebar, where AppKit receives the mouse and UIKit never sees the click. The
/// glue's ChalkTitlebarBandView catches those clicks and forwards the point;
/// `replayTitlebarBandClick` is what turns a point back into the tap it would
/// have been. These tests drive that replay directly — the AppKit half can only
/// be checked in the running Mac app, but the UIKit half is plain hit-testing.
final class SidebarTitlebarBandTests: XCTestCase {
    private func tempTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-band-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# a\n".utf8).write(to: root.appendingPathComponent("a.md"))
        try Data("# b\n".utf8).write(to: root.appendingPathComponent("b.md"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A sidebar in a real window, laid out: the replay hit-tests live frames,
    /// so an off-window controller would report nothing at every point.
    private func makeSidebar(root: URL) -> (SidebarViewController, UIWindow) {
        let sidebar = SidebarViewController()
        sidebar.locationsProvider = { [Location(id: "test", name: "Test", url: root)] }
        let window = UIWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        window.rootViewController = sidebar
        window.isHidden = false
        sidebar.loadViewIfNeeded()
        sidebar.reload()
        window.layoutIfNeeded()
        sidebar.collectionViewForTesting.layoutIfNeeded()
        return (sidebar, window)
    }

    private func headerFrameInWindow(
        _ sidebar: SidebarViewController, _ window: UIWindow
    ) throws -> CGRect {
        let collection = sidebar.collectionViewForTesting
        let header = try XCTUnwrap(collection.visibleSupplementaryViews(
            ofKind: UICollectionView.elementKindSectionHeader).first,
            "the Location header should be laid out")
        return collection.convert(header.frame, to: window)
    }

    func testClickOnLocationHeaderFoldsIt() throws {
        let root = try tempTree()
        let (sidebar, window) = makeSidebar(root: root)
        XCTAssertFalse(sidebar.isLocationCollapsedForTesting("test"))

        let header = try headerFrameInWindow(sidebar, window)
        sidebar.replayTitlebarBandClick(atWindowPoint: CGPoint(x: header.midX, y: header.midY))
        XCTAssertTrue(sidebar.isLocationCollapsedForTesting("test"),
                      "a forwarded click on the header should fold the Location")

        sidebar.replayTitlebarBandClick(atWindowPoint: CGPoint(x: header.midX, y: header.midY))
        XCTAssertFalse(sidebar.isLocationCollapsedForTesting("test"),
                       "and the next one should unfold it")
    }

    func testClickOnFileRowOpensIt() throws {
        let root = try tempTree()
        let (sidebar, window) = makeSidebar(root: root)
        var opened: URL?
        sidebar.onOpenFile = { opened = $0 }

        let collection = sidebar.collectionViewForTesting
        let first = IndexPath(item: 0, section: 0)
        let attributes = try XCTUnwrap(collection.layoutAttributesForItem(at: first))
        let expected = try XCTUnwrap(sidebar.itemURLForTesting(at: first))

        sidebar.replayTitlebarBandClick(
            atWindowPoint: collection.convert(attributes.center, to: window))
        XCTAssertEqual(opened, expected, "a forwarded click on a row should open that file")
    }

    /// The band forwards every click it caught over the panel's column, which
    /// includes points above the tree (the glass edge) — those must stay inert
    /// rather than activating whatever row is nearest.
    func testClickOutsideAnyRowDoesNothing() throws {
        let root = try tempTree()
        let (sidebar, window) = makeSidebar(root: root)
        // Bound, not discarded: the window owns the view hierarchy the replay
        // hit-tests against, so letting it go would change what this asserts.
        _ = window
        var opened: URL?
        sidebar.onOpenFile = { opened = $0 }

        sidebar.replayTitlebarBandClick(atWindowPoint: CGPoint(x: 4, y: 2))
        XCTAssertNil(opened)
        XCTAssertFalse(sidebar.isLocationCollapsedForTesting("test"))
    }
}
