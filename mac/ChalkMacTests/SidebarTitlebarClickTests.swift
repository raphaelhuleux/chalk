import XCTest
import ChalkKit
@testable import ChalkMac

/// The Library's top rows sit under the transparent titlebar, as do the tab
/// names. On Catalyst that region belonged to AppKit and a glue view had to
/// replay the clicks; here the window must hand them to the views directly.
/// The window's own hit-testing (the frame view, which `sendEvent` consults)
/// is what decides, so these ask it, through the app's real window.
@MainActor
final class SidebarTitlebarClickTests: XCTestCase {
    private var controller: EditorWindowController!
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-titlebar-click-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("# a\n".utf8).write(to: dir.appendingPathComponent("a.md"))
        try Data("# b\n".utf8).write(to: dir.appendingPathComponent("b.md"))
        controller = EditorWindowController(initialContent: .openEmpty)
        controller.showWindow(nil)
        let root = controller.root
        root.motionPolicyForTesting = .instant
        root.setLibraryLocationsForTesting([dir])
        root.applyTransitionForTesting(.sidebar(true))
        settle()
    }

    override func tearDownWithError() throws {
        controller.close()
        controller = nil
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private var window: NSWindow { controller.window! }
    private var root: RootSplitViewController { controller.root }
    private var sidebar: SidebarViewController { root.sidebarForTesting }

    private func settle() {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            root.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// The view a click at `point` (window coordinates) reaches, as the window
    /// resolves it: the frame view is the window's whole view tree, titlebar included.
    private func hit(_ point: NSPoint) throws -> NSView? {
        let frameView = try XCTUnwrap(window.contentView?.superview, "the window's frame view")
        return frameView.hitTest(point)
    }

    private func windowPoint(ofRow row: Int) -> NSPoint {
        let rect = sidebar.outlineViewForTesting.rect(ofRow: row)
        return sidebar.outlineViewForTesting.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    /// Precondition for the suite: the first header sits on the chrome floor,
    /// the top edge of the band being the window's titlebar region.
    private func assertHeaderSitsOnTheChromeFloor() throws {
        let header = try XCTUnwrap(sidebar.firstHeaderFrameForTesting)
        let inRoot = root.view.convert(header, from: sidebar.view)
        XCTAssertEqual(inRoot.minY, root.chromeReserveForTesting, accuracy: 1.5,
                       "the first header starts where the chrome ends")
    }

    func testAClickOnTheLocationHeaderReachesTheTree() throws {
        try assertHeaderSitsOnTheChromeFloor()
        let point = windowPoint(ofRow: 0)
        let view = try hit(point)
        XCTAssertTrue(view?.isDescendant(of: sidebar.outlineViewForTesting) == true,
                      "the titlebar must not take the click; it hit \(String(describing: view))")
    }

    /// The panel's slice of the band, above the first header, is cut out of
    /// the band's paint and its clicks belong to the Library's surface, not
    /// to the band and not to the titlebar.
    func testAClickInTheBandOverTheLibraryReachesTheLibrary() throws {
        let reserve = root.chromeReserveForTesting
        XCTAssertGreaterThan(reserve, 10, "precondition: the chrome reserves a band")
        let point = root.view.convert(NSPoint(x: 100, y: reserve - 8), to: nil)
        let view = try hit(point)
        XCTAssertTrue(view?.isDescendant(of: root.sidebarColumnForTesting) == true,
                      "the band's Library hole must pass the click down; it hit \(String(describing: view))")
    }

    func testAClickOnTheFirstRowReachesTheTree() throws {
        let point = windowPoint(ofRow: 1)
        let view = try hit(point)
        XCTAssertTrue(view?.isDescendant(of: sidebar.outlineViewForTesting) == true,
                      "the first row sits under the titlebar too; it hit \(String(describing: view))")
    }

    /// The tab names are in the same band, on the editor's side.
    func testAClickOnTheTabStripReachesTheStrip() throws {
        root.editorForTesting.open(url: dir.appendingPathComponent("a.md"))
        settle()
        let strip = root.chromeLayout(for: UIState(window: .windowed, sidebar: .shown,
                                                   mode: .normal, appearance: .light)).tabStrip
        XCTAssertFalse(strip.isEmpty, "precondition: the strip is laid out")
        let point = root.view.convert(NSPoint(x: strip.midX, y: strip.midY), to: nil)
        let view = try hit(point)
        XCTAssertTrue(view?.isDescendant(of: root.headerBarForTesting) == true,
                      "the strip must take its own clicks; it hit \(String(describing: view))")
    }

    /// The clicks do what a click does: a header folds, a row opens.
    func testTheClicksFoldAndOpen() throws {
        let outlineView = sidebar.outlineViewForTesting
        let header = outlineView.rect(ofRow: 0)
        sidebar.clickForTesting(at: NSPoint(x: header.midX, y: header.midY))
        XCTAssertTrue(sidebar.isLocationCollapsedForTesting(dir.lastPathComponent))
        sidebar.clickForTesting(at: NSPoint(x: header.midX, y: header.midY))
        XCTAssertFalse(sidebar.isLocationCollapsedForTesting(dir.lastPathComponent))
        settle()

        var opened: URL?
        sidebar.onOpenFile = { opened = $0 }
        let row = outlineView.rect(ofRow: 1)
        sidebar.clickForTesting(at: NSPoint(x: row.midX, y: row.midY))
        XCTAssertEqual(opened, sidebar.itemURLForTesting(at: IndexPath(item: 0, section: 0)))

        opened = nil
        sidebar.clickForTesting(at: NSPoint(x: 4, y: -40))
        XCTAssertNil(opened, "a click outside any row stays inert")
    }
}
