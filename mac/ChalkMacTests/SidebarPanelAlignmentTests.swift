import XCTest
import ChalkKit
@testable import ChalkMac

/// Since Paper (2026-08-24) the Library panel has no insets: a flat surface
/// that stops short of the window reads as a floating card, which is the
/// treatment the direction removed.
///
/// The rule under test: the panel fills its column, flush with the window,
/// and never leaves the column while the column is mid-slide.
@MainActor
final class SidebarPanelAlignmentTests: XCTestCase {
    private var window: NSWindow!
    private var host: NSViewController!
    private var sidebar: SidebarViewController!

    override func setUp() {
        super.setUp()
        sidebar = SidebarViewController()
        host = NSViewController()
        host.view = FlippedView()
        window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = host
        window.isHidden = false
        // Frame-hosted child, so each test can place the column exactly where
        // the root would.
        host.addChild(sidebar)
        sidebar.view.translatesAutoresizingMaskIntoConstraints = true
        host.view.addSubview(sidebar.view)
    }

    override func tearDown() {
        dismantleHostedSidebar(window)
        window = nil
        host = nil
        sidebar = nil
        super.tearDown()
    }

    private func layoutColumn(_ frame: CGRect) {
        sidebar.view.frame = frame
        window.layoutIfNeeded()
        sidebar.view.layoutSubtreeIfNeeded()
    }

    private var panelInWindow: CGRect {
        host.view.convert(sidebar.panelFrameForTesting, from: sidebar.view)
    }

    func testClassicColumnIsAlreadyFlushAndStaysFlush() {
        // The column fills the window, and the panel simply fills it.
        layoutColumn(host.view.bounds)

        XCTAssertEqual(panelInWindow.minX, 0, accuracy: 0.5)
        XCTAssertEqual(panelInWindow.minY, 0, accuracy: 0.5,
                       "flush with the window's top")
        XCTAssertEqual(panelInWindow.maxY, host.view.bounds.maxY, accuracy: 0.5)
    }

    // MARK: - Mid-transition frames (the "panel is sometimes empty" report)

    /// The column's origin is negative while it slides in. Following it would
    /// drag the panel out of its own column: the Library reads as empty even
    /// though the model is fully populated.
    func testColumnSlidingInFromTheLeftKeepsThePanelInItsColumn() {
        layoutColumn(CGRect(x: -220, y: 0, width: 300, height: host.view.bounds.height))

        let panel = sidebar.panelFrameForTesting
        XCTAssertEqual(panel.minX, 0, accuracy: 0.5,
                       "a negative column origin must not move the panel inside its column")
        XCTAssertLessThan(panel.maxX, sidebar.view.bounds.width + 0.5,
                          "the panel must stay inside its column")
        XCTAssertGreaterThan(panel.width, 0)
    }

    /// Same family, vertical: a column whose origin sits above the window
    /// must not push the panel down.
    func testColumnAboveTheWindowKeepsThePanelAtItsColumnTop() {
        layoutColumn(CGRect(x: 0, y: -180, width: 300, height: host.view.bounds.height))

        let panel = sidebar.panelFrameForTesting
        XCTAssertLessThanOrEqual(panel.minY, 0.5,
                                 "a negative column origin must not inflate the top inset")
        XCTAssertGreaterThan(panel.height, 0)
    }

    /// A column taller than the window (mid-resize) must not invert the
    /// bottom constraint into a zero/negative-height panel.
    func testOversizedColumnKeepsAPositivePanelHeight() {
        layoutColumn(CGRect(x: 0, y: 0, width: 300, height: host.view.bounds.height + 300))

        XCTAssertGreaterThan(sidebar.panelFrameForTesting.height, 0)
    }

    /// The Library's layout pass writes constraints (the tree top), which
    /// schedules another pass: it has to reach a FIXED POINT, or the app spins
    /// in layout and freezes with the Library open.
    func testRepeatedLayoutPassesSettleInsteadOfChasingTheirOwnConstants() {
        layoutColumn(CGRect(x: 10, y: 32, width: 300, height: host.view.bounds.height - 42))
        let settled = sidebar.panelFrameForTesting

        for pass in 1...5 {
            sidebar.view.needsLayout = true
            sidebar.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(sidebar.panelFrameForTesting, settled,
                           "layout pass \(pass) moved the panel again: the layout is chasing itself")
        }
    }
}
