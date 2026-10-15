import XCTest
import ChalkKit
@testable import ChalkMac

/// M-8: the tab-close fade completion must rebuild from the NEWEST model
/// (`latestItems`), not from the `items` array the animating update captured.
/// A second update landing inside the 0.15s fade window used to be reverted
/// by the completion — closed tab resurrected, freshly opened tab hidden
/// until the next unrelated update.
final class HeaderTabStripTests: XCTestCase {
    private var window: NSWindow!
    private var strip: HeaderTabStrip!

    override func setUp() {
        super.setUp()
        // The animated close path is gated on `window != nil`, so the strip
        // must live in a real (hosted-test) window.
        window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 600, height: 44))
        strip = HeaderTabStrip(frame: CGRect(x: 0, y: 0, width: 600, height: 44))
        window.addSubview(strip)
        window.isHidden = false
    }

    override func tearDown() {
        strip.removeFromSuperview()
        window.isHidden = true
        window = nil
        strip = nil
        super.tearDown()
    }

    private func item(_ name: String, active: Bool = false) -> TabItem {
        TabItem(id: UUID(), name: name, isDirty: false, isActive: active, isPreview: false)
    }

    /// Let the ChalkMetrics.motionFast (0.15s) fade and its completion land.
    private func waitForFadeCompletion() {
        let exp = expectation(description: "close-fade completion")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exp.fulfill() }
        wait(for: [exp], timeout: 3)
    }

    func testUpdateDuringCloseFadeIsNotRevertedByTheFadeCompletion() {
        let a = item("a", active: true), b = item("b"), c = item("c")
        strip.update([a, b, c])
        // Close c: exactly one chip gone, same shape → the animated path.
        strip.update([a, b])
        // A NEWER model lands inside the fade window (a new tab d opened).
        let d = item("d")
        strip.update([a, b, d])
        waitForFadeCompletion()
        // The stale completion must not resurrect [a, b].
        XCTAssertEqual(strip.renderedTabIDsForTesting, [a.id, b.id, d.id])
    }

    func testCloseFadeStillLandsOnTheClosedModel() {
        let a = item("a", active: true), b = item("b")
        strip.update([a, b])
        strip.update([a]) // animated close, no interleaved update
        waitForFadeCompletion()
        XCTAssertEqual(strip.renderedTabIDsForTesting, [a.id])
    }

    func testTwoClosesInsideOneFadeWindowConvergeToTheLatest() {
        let a = item("a", active: true), b = item("b"), c = item("c")
        strip.update([a, b, c])
        strip.update([a, b]) // animated close of c
        strip.update([a])    // second close before the first fade completes
        waitForFadeCompletion()
        XCTAssertEqual(strip.renderedTabIDsForTesting, [a.id])
    }
}
