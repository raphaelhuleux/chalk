import XCTest
@testable import ChalkKit

/// The iA-style auto-hide contract: deliberate downward travel hides, a quick or long scroll
/// back up reveals, the top of the document always reveals, and neither jitter nor the slow
/// upward drift of reading flaps the chrome.
final class ChromeAutoHidePolicyTests: XCTestCase {
    /// Feeds timed samples: `step` seconds apart, 60 frames a second by default.
    private struct Driver {
        var policy = ChromeAutoHidePolicy()
        var time: Double = 100

        @discardableResult
        mutating func scroll(_ offsets: [Double], step: Double = 1.0 / 60, canHide: Bool = true)
            -> ChromeAutoHidePolicy.Chrome {
            for offset in offsets {
                time += step
                policy.observe(offset: offset, at: time, canHide: canHide)
            }
            return policy.chrome
        }

        /// Hidden, resting at `offset` (a downward run from 40pt above it).
        static func hidden(at offset: Double) -> Driver {
            var driver = Driver()
            driver.scroll([offset - 40, offset])
            return driver
        }
    }

    func testStartsShown() {
        var driver = Driver()
        XCTAssertEqual(driver.scroll([100]), .shown, "the first sample only seeds the baseline")
    }

    func testSmallDownScrollStaysShown() {
        var driver = Driver()
        XCTAssertEqual(driver.scroll([100, 110]), .shown, "10pt is under the hide threshold")
    }

    func testCumulativeDownScrollHides() {
        var driver = Driver()
        XCTAssertEqual(driver.scroll([100, 110, 120, 130]), .hidden,
                       "30pt of downward travel crosses the hide threshold")
    }

    func testAQuickFlickUpReveals() {
        var driver = Driver.hidden(at: 1000)
        XCTAssertEqual(driver.scroll([960, 920, 880]), .shown, "120pt in three frames is a reach for the tabs")
    }

    func testASmallQuickNudgeUpStaysHidden() {
        var driver = Driver.hidden(at: 1000)
        XCTAssertEqual(driver.scroll([970, 940]), .hidden, "60pt is under the flick distance")
    }

    /// Re-reading: a slow climb, a few points a frame, never reaches the flick rate.
    func testASlowUpwardDriftStaysHidden() {
        var driver = Driver.hidden(at: 1000)
        let drift = (1...40).map { 1000 - Double($0) * 5 }   // 200pt over 40 frames at 10 fps
        XCTAssertEqual(driver.scroll(drift, step: 0.1), .hidden, "200pt at 50pt/s is reading, not reaching")
    }

    func testALongClimbRevealsAtAnySpeed() {
        var driver = Driver.hidden(at: 1000)
        let climb = (1...70).map { 1000 - Double($0) * 5 }   // 350pt at 50pt/s
        XCTAssertEqual(driver.scroll(climb, step: 0.1), .shown, "a 300pt climb is deliberate however slow")
    }

    func testAPauseStartsANewGesture() {
        var quick = Driver.hidden(at: 1000)
        XCTAssertEqual(quick.scroll([940, 880]), .shown, "two 60pt moves in one gesture are a flick")
        var paused = Driver.hidden(at: 1000)
        paused.scroll([940])
        XCTAssertEqual(paused.scroll([880], step: 0.5), .hidden,
                       "the same two moves half a second apart are two gestures")
    }

    func testPausedNudgesNeverAddUpToALongClimb() {
        var driver = Driver.hidden(at: 1000)
        for i in 1...10 {
            driver.scroll([1000 - Double(i) * 40], step: 0.6)   // 400pt in 40pt nudges, 0.6s apart
        }
        XCTAssertEqual(driver.policy.chrome, .hidden)
    }

    func testNearTopAlwaysShows() {
        var driver = Driver.hidden(at: 140)
        XCTAssertEqual(driver.scroll([5]), .shown, "landing near the top reveals regardless of history")
    }

    func testRubberBandNegativeOffsetShows() {
        var driver = Driver.hidden(at: 140)
        XCTAssertEqual(driver.scroll([-12]), .shown)
    }

    func testDirectionFlipResetsAccumulation() {
        var driver = Driver()
        driver.scroll([100, 120, 115, 135])   // down 20, up 5, down 20
        XCTAssertEqual(driver.policy.chrome, .shown, "no single downward run crossed the threshold")
        XCTAssertEqual(driver.scroll([145]), .hidden, "another 10pt completes a 30pt downward run")
    }

    func testJitterDoesNotFlap() {
        var driver = Driver.hidden(at: 260)
        for offset in [258.0, 261, 259, 262, 260, 258] {
            XCTAssertEqual(driver.scroll([offset]), .hidden, "±3pt of jitter must not reveal (offset \(offset))")
        }
    }

    /// A jump down the document is no scroll: the tabs stay.
    func testAMoveTheReaderDidNotScrollNeverHides() {
        var driver = Driver()
        driver.scroll([0], canHide: false)
        XCTAssertEqual(driver.scroll([5000], canHide: false), .shown)
        XCTAssertEqual(driver.scroll([5010]), .shown, "the jump leaves no run behind")
    }

    func testAMoveTheReaderDidNotScrollStillReveals() {
        var driver = Driver.hidden(at: 1000)
        XCTAssertEqual(driver.scroll([700], canHide: false), .shown)
    }
}
