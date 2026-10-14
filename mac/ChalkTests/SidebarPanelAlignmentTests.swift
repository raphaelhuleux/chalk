import XCTest
@testable import Chalk

/// Since Paper (2026-08-24) the Library panel has no insets: a flat surface
/// that stops short of the window reads as a floating card, which is the
/// treatment the direction removed.
///
/// The rule under test: the panel fills its column, flush with the window,
/// and never leaves the column while the column is mid-slide.
@MainActor
final class SidebarPanelAlignmentTests: XCTestCase {
    private var window: UIWindow!
    private var host: UIViewController!
    private var sidebar: SidebarViewController!

    override func setUp() {
        super.setUp()
        sidebar = SidebarViewController()
        host = UIViewController()
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first!
        window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        // Frame-hosted child, so each test can place the column exactly where
        // the split view would.
        host.addChild(sidebar)
        sidebar.view.translatesAutoresizingMaskIntoConstraints = true
        host.view.addSubview(sidebar.view)
        sidebar.didMove(toParent: host)
    }

    override func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        host = nil
        sidebar = nil
        super.tearDown()
    }

    private func layoutColumn(_ frame: CGRect) {
        sidebar.view.frame = frame
        window.layoutIfNeeded()
        sidebar.view.layoutIfNeeded()
    }

    private var panelInWindow: CGRect {
        sidebar.view.convert(sidebar.panelFrameForTesting, to: window)
    }

    func testClassicColumnIsAlreadyFlushAndStaysFlush() {
        // The column fills the window, and the panel simply fills it.
        layoutColumn(window.bounds)

        XCTAssertEqual(panelInWindow.minX, 0, accuracy: 0.5)
        XCTAssertEqual(panelInWindow.minY, 0, accuracy: 0.5,
                       "flush with the window's top")
        XCTAssertEqual(panelInWindow.maxY, window.bounds.maxY, accuracy: 0.5)
    }

    // MARK: - Mid-transition frames (the "panel is sometimes empty" report)

    /// The column's WINDOW origin is negative while the split view slides the
    /// column in. Following it would drag the panel out of its own column: the
    /// Library reads as empty even though the data source is fully populated.
    func testColumnSlidingInFromTheLeftKeepsThePanelInItsColumn() {
        layoutColumn(CGRect(x: -220, y: 0, width: 300, height: window.bounds.height))

        let panel = sidebar.panelFrameForTesting
        XCTAssertEqual(panel.minX, 0, accuracy: 0.5,
                       "a negative column origin must not move the panel inside its column")
        XCTAssertLessThan(panel.maxX, sidebar.view.bounds.width + 0.5,
                          "the panel must stay inside its column")
        XCTAssertGreaterThan(panel.width, 0)
    }

    /// Same family, vertical: a column whose origin sits above the window (the
    /// first pass of a restore) must not push the panel down.
    func testColumnAboveTheWindowKeepsThePanelAtItsColumnTop() {
        layoutColumn(CGRect(x: 0, y: -180, width: 300, height: window.bounds.height))

        let panel = sidebar.panelFrameForTesting
        XCTAssertLessThanOrEqual(panel.minY, 0.5,
                                 "a negative column origin must not inflate the top inset")
        XCTAssertGreaterThan(panel.height, 0)
    }

    /// A column taller than the window (mid-resize) must not invert the
    /// bottom constraint into a zero/negative-height panel.
    func testOversizedColumnKeepsAPositivePanelHeight() {
        layoutColumn(CGRect(x: 0, y: 0, width: 300, height: window.bounds.height + 300))

        XCTAssertGreaterThan(sidebar.panelFrameForTesting.height, 0)
    }

    /// The Library's layout pass writes constraints (the tree top), which
    /// schedules another pass: it has to reach a FIXED POINT, or the app spins
    /// in layout and freezes with the Library open.
    func testRepeatedLayoutPassesSettleInsteadOfChasingTheirOwnConstants() {
        let floatTop = max(window.safeAreaInsets.top, 32)
        layoutColumn(CGRect(x: 10, y: floatTop, width: 300,
                            height: window.bounds.height - floatTop - 10))
        let settled = sidebar.panelFrameForTesting

        for pass in 1...5 {
            sidebar.view.setNeedsLayout()
            sidebar.view.layoutIfNeeded()
            XCTAssertEqual(sidebar.panelFrameForTesting, settled,
                           "layout pass \(pass) moved the panel again: the layout is chasing itself")
        }
    }
}
