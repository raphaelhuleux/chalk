import XCTest
@testable import Chalk

/// The panel's geometry inside the editor column: push while the column can
/// spare the width, overlay once the text would fall below the floor.
@MainActor
final class OutlinePanelLayoutTests: XCTestCase {
    private static let widthKey = "chalk.outlinePanelWidth"
    private var savedWidth: Any?

    override func setUp() {
        super.setUp()
        savedWidth = UserDefaults.standard.object(forKey: Self.widthKey)
        UserDefaults.standard.removeObject(forKey: Self.widthKey)
    }

    override func tearDown() {
        if let savedWidth {
            UserDefaults.standard.set(savedWidth, forKey: Self.widthKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.widthKey)
        }
        super.tearDown()
    }

    private func hosted(width: CGFloat) -> (UIWindow, EditorContainerViewController) {
        let window = UIWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: width, height: 800))
        let container = EditorContainerViewController()
        window.rootViewController = container
        window.makeKeyAndVisible()
        container.view.layoutIfNeeded()
        return (window, container)
    }

    func testHiddenPanelReportsNoFrameAndFullWidthContent() {
        let (_, container) = hosted(width: 1200)
        XCTAssertNil(container.outlinePanelFrame)
        XCTAssertEqual(container.contentViewFrameForTesting.maxX, 1200, accuracy: 0.5)
    }

    func testWideColumnPushesTheEditor() {
        let (_, container) = hosted(width: 1200)
        container.setOutlinePanelVisible(true, animated: false)
        container.view.layoutIfNeeded()
        let panel = try! XCTUnwrap(container.outlinePanelFrame)
        XCTAssertFalse(container.outlinePanelIsOverlay)
        XCTAssertEqual(panel.maxX, 1200, accuracy: 0.5)
        XCTAssertEqual(panel.width, Preferences.outlinePanelWidth, accuracy: 0.5)
        XCTAssertEqual(container.contentViewFrameForTesting.maxX, panel.minX, accuracy: 0.5)
    }

    func testNarrowColumnOverlaysTheEditor() {
        let width = ChalkMetrics.outlinePanelPushMinimumEditorWidth + Preferences.outlinePanelWidth - 10
        let (_, container) = hosted(width: width)
        container.setOutlinePanelVisible(true, animated: false)
        container.view.layoutIfNeeded()
        let panel = try! XCTUnwrap(container.outlinePanelFrame)
        XCTAssertTrue(container.outlinePanelIsOverlay)
        XCTAssertEqual(container.contentViewFrameForTesting.maxX, panel.maxX, accuracy: 0.5)
    }

    func testModeFollowsAWindowResize() {
        let (window, container) = hosted(width: 1200)
        container.setOutlinePanelVisible(true, animated: false)
        container.view.layoutIfNeeded()
        XCTAssertFalse(container.outlinePanelIsOverlay)
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        window.layoutIfNeeded()
        container.view.layoutIfNeeded()
        XCTAssertTrue(container.outlinePanelIsOverlay)
    }

    func testHidingRestoresTheFullWidthColumn() {
        let (_, container) = hosted(width: 1200)
        container.setOutlinePanelVisible(true, animated: false)
        container.setOutlinePanelVisible(false, animated: false)
        container.view.layoutIfNeeded()
        XCTAssertNil(container.outlinePanelFrame)
        XCTAssertEqual(container.contentViewFrameForTesting.maxX, 1200, accuracy: 0.5)
    }

    func testResizeClampsAndPersists() {
        let (_, container) = hosted(width: 1200)
        container.setOutlinePanelVisible(true, animated: false)
        container.setOutlinePanelWidth(10_000, persist: true)
        XCTAssertEqual(container.outlinePanelWidthForTesting, Preferences.sidebarWidthRange.upperBound)
        XCTAssertEqual(Preferences.outlinePanelWidth, Preferences.sidebarWidthRange.upperBound)
        container.setOutlinePanelWidth(1, persist: false)
        XCTAssertEqual(container.outlinePanelWidthForTesting, Preferences.sidebarWidthRange.lowerBound)
        XCTAssertEqual(Preferences.outlinePanelWidth, Preferences.sidebarWidthRange.upperBound,
                       "persist: false must not write")
    }

    /// Exactly one of the content's two trailing pins is ever active — never
    /// both (a torn-down layout) and never neither (the content stranded with
    /// no trailing edge at all).
    func testExactlyOnePinIsActiveThroughShowResizeHide() {
        let (window, container) = hosted(width: 1200)
        XCTAssertEqual(container.activeContentTrailingPinForTesting, "edge", "hidden starts full-width")

        container.setOutlinePanelVisible(true, animated: false)
        container.view.layoutIfNeeded()
        XCTAssertEqual(container.activeContentTrailingPinForTesting, "panel", "wide column pushes")

        window.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        window.layoutIfNeeded()
        container.view.layoutIfNeeded()
        XCTAssertEqual(container.activeContentTrailingPinForTesting, "edge", "narrowed past the floor")

        container.setOutlinePanelVisible(false, animated: false)
        container.view.layoutIfNeeded()
        XCTAssertEqual(container.activeContentTrailingPinForTesting, "edge", "hidden again")
    }

    /// Fix round 1, finding 2: a frozen content width (mid `freezeContentWidth`
    /// sidebar slide) must never have its trailing pin swapped underneath it —
    /// that would jump the frozen content sideways by the panel's width,
    /// fighting `slideContent`'s translation. The mode only catches up with a
    /// resize that happened during the freeze once `unfreezeContentWidth` runs
    /// the real reflow.
    func testFrozenContentWidthIgnoresAResizeUntilUnfrozen() {
        let (window, container) = hosted(width: 1200)
        container.setOutlinePanelVisible(true, animated: false)
        container.view.layoutIfNeeded()
        XCTAssertEqual(container.activeContentTrailingPinForTesting, "panel")

        container.freezeContentWidth()
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        window.layoutIfNeeded()
        container.view.layoutIfNeeded()
        XCTAssertEqual(container.activeContentTrailingPinForTesting, "panel",
                       "frozen content must not be re-pinned mid-slide")
        XCTAssertFalse(container.outlinePanelIsOverlay, "mode must not flip while frozen")

        container.unfreezeContentWidth()
        XCTAssertEqual(container.activeContentTrailingPinForTesting, "edge",
                       "unfreezing catches up with the resize that happened underneath it")
        XCTAssertTrue(container.outlinePanelIsOverlay)
    }

    /// Fix round 1, finding 1: a double toggle inside one `motionSidebar`
    /// window (open, close, open again, all animated) must not leave the
    /// panel invisible while `isOutlinePanelVisible` says it's open — the
    /// first close's completion fires after the second open and must not
    /// unconditionally hide.
    func testDoubleToggleWithinOneAnimationLeavesThePanelVisible() {
        let (_, container) = hosted(width: 1200)
        container.setOutlinePanelVisible(true, animated: true)
        container.setOutlinePanelVisible(false, animated: true)
        container.setOutlinePanelVisible(true, animated: true)

        let deadline = Date(timeIntervalSinceNow: 0.4)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }

        XCTAssertTrue(container.isOutlinePanelVisible)
        XCTAssertFalse(container.outlinePanel.view.isHidden,
                       "the panel must still be showing after the stale hide's completion fires")
    }

    /// The header sits at its fixed distance from the panel's top whatever
    /// the host pushes as the text's resting inset: the panel is a full
    /// column like the Library, not a list parked under the band.
    func testPanelHeaderIgnoresTheChromeInset() {
        let (_, container) = hosted(width: 1200)
        container.setOutlinePanelVisible(true, animated: false)
        container.setChromeTopInset(200)
        container.view.layoutIfNeeded()
        XCTAssertEqual(container.outlinePanel.headerFrameForTesting.minY,
                       OutlinePanelViewController.headerTop, accuracy: 0.5)
    }

    /// The panel is chrome, like the Library: it paints to the window's top
    /// edge and its rows scroll under the titlebar. The editor's chrome fade
    /// (editor-coloured, full width, as tall as the text's resting inset)
    /// must therefore sit BELOW the panel, or it paints the editor's paper
    /// over the panel's top band (owner report 2026-09-05).
    func testPanelSitsAboveTheChromeFade() {
        let (_, container) = hosted(width: 1200)
        container.setOutlinePanelVisible(true, animated: false)
        container.setChromeTopInset(80)
        container.view.layoutIfNeeded()
        XCTAssertTrue(container.isOutlinePanelAboveChromeFadeForTesting)
    }

    /// The resize grip straddles the panel's edge, half over the editor and
    /// half over the panel, so a drag that starts on the visible border
    /// catches it from either side (owner report 2026-09-05: the grip used
    /// to sit entirely inside the panel, six points wide, and was
    /// unfindable). It goes away with the panel so nothing intercepts clicks
    /// at the window's trailing edge while the panel is parked off-screen.
    func testResizeGripStraddlesThePanelEdge() {
        let (_, container) = hosted(width: 1200)
        XCTAssertTrue(container.outlineResizeGripIsHiddenForTesting)
        container.setOutlinePanelVisible(true, animated: false)
        container.view.layoutIfNeeded()
        let panel = try! XCTUnwrap(container.outlinePanelFrame)
        let grip = container.outlineResizeGripFrameForTesting
        XCTAssertFalse(container.outlineResizeGripIsHiddenForTesting)
        XCTAssertEqual(grip.midX, panel.minX, accuracy: 0.5)
        XCTAssertEqual(grip.width, ChalkMetrics.s(12), accuracy: 0.5)
        XCTAssertEqual(grip.minY, panel.minY, accuracy: 0.5)
        XCTAssertEqual(grip.maxY, panel.maxY, accuracy: 0.5)
        container.setOutlinePanelVisible(false, animated: false)
        XCTAssertTrue(container.outlineResizeGripIsHiddenForTesting)
    }
}
