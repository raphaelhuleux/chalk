import XCTest
import ChalkKit
@testable import Chalk

/// The app's own window through a REAL full-screen round trip (`toggleFullScreen`, not the
/// matrix's flag): the titlebar must come back tall, the row back on the lights' line, and a
/// band that had scrolled away must be on screen again
/// (docs/issues/2026-11-16-tab-row-regressions.md). Slow (two system transitions per test),
/// so the checks share one round trip.
@MainActor
final class WindowModeRoundTripTests: XCTestCase {
    private func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The row's line, in window coordinates: the "+" sits on it (`TabRowGeometryTests`) and
    /// shows even with no tabs open.
    private func rowLine(_ root: RootSplitViewController) -> CGFloat? {
        guard let strip = root.tabStripsForTesting.first else { return nil }
        return strip.convert(strip.newTabButtonFrameForTesting, to: nil).midY
    }

    private func lightsLine(_ window: NSWindow) -> CGFloat? {
        guard let zoom = window.standardWindowButton(.zoomButton), let host = zoom.superview else { return nil }
        return host.convert(zoom.frame, to: nil).midY
    }

    private func toggle(_ window: NSWindow, to fullscreen: Bool) {
        window.toggleFullScreen(nil)
        let deadline = Date().addingTimeInterval(8)
        while window.styleMask.contains(.fullScreen) != fullscreen, Date() < deadline { wait(0.1) }
        wait(1.0) // the exit's titlebar settles after the style mask flips
    }

    func testAFullScreenRoundTripKeepsTheRowOnTheLightsAndTheBandOnScreen() throws {
        let controller = EditorWindowController(initialContent: .openEmpty)
        controller.showWindow(nil)
        defer { controller.close() }
        wait(1.5)
        let window = try XCTUnwrap(controller.window)
        let root = controller.root

        let before = try XCTUnwrap(rowLine(root))
        XCTAssertEqual(before, try XCTUnwrap(lightsLine(window)), accuracy: 1.0, "windowed, before")
        XCTAssertEqual(window.toolbar?.isVisible, true)

        // Scroll the band away, then round-trip.
        for offset in [20.0, 60, 120, 200, 300] { root.editorDidScroll(offset: offset, canHide: true) }
        wait(0.5)
        XCTAssertTrue(root.isChromeAutoHiddenForTesting, "precondition: the band scrolled away")

        toggle(window, to: true)
        XCTAssertTrue(window.styleMask.contains(.fullScreen), "the system did not enter full screen")
        XCTAssertFalse(root.isChromeAutoHiddenForTesting, "entering full screen leaves the band hidden")

        for offset in [320.0, 400, 500, 600] { root.editorDidScroll(offset: offset, canHide: true) }
        wait(0.5)
        toggle(window, to: false)
        XCTAssertFalse(window.styleMask.contains(.fullScreen))

        XCTAssertFalse(root.isChromeAutoHiddenForTesting, "leaving full screen leaves the band hidden")
        XCTAssertFalse(root.isHeaderHiddenForTesting)
        XCTAssertEqual(window.toolbar?.isVisible, true, "the titlebar came back short")
        let after = try XCTUnwrap(rowLine(root))
        XCTAssertEqual(after, try XCTUnwrap(lightsLine(window)), accuracy: 1.0, "windowed, after the round trip")
        XCTAssertEqual(after, before, accuracy: 0.5)
    }
}
