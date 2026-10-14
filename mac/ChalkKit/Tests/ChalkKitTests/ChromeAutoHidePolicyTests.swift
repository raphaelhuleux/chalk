import XCTest
@testable import ChalkKit

/// The iA-style auto-hide contract: deliberate downward travel hides, eager
/// upward travel reveals, the top of the document always reveals, and scroll
/// jitter never flaps the chrome.
final class ChromeAutoHidePolicyTests: XCTestCase {
    func testStartsShown() {
        var policy = ChromeAutoHidePolicy()
        XCTAssertEqual(policy.observe(offset: 100), .shown,
                       "the first sample only seeds the baseline")
    }

    func testSmallDownScrollStaysShown() {
        var policy = ChromeAutoHidePolicy()
        policy.observe(offset: 100)
        XCTAssertEqual(policy.observe(offset: 110), .shown,
                       "10pt is under the hide threshold")
    }

    func testCumulativeDownScrollHides() {
        var policy = ChromeAutoHidePolicy()
        policy.observe(offset: 100)
        policy.observe(offset: 110)
        policy.observe(offset: 120)
        XCTAssertEqual(policy.observe(offset: 130), .hidden,
                       "30pt of accumulated downward travel crosses the threshold")
    }

    func testUpScrollReveals() {
        var policy = ChromeAutoHidePolicy()
        policy.observe(offset: 100)
        policy.observe(offset: 140) // hidden
        policy.observe(offset: 133)
        XCTAssertEqual(policy.observe(offset: 126), .shown,
                       "14pt of upward travel crosses the (smaller) show threshold")
    }

    func testNearTopAlwaysShows() {
        var policy = ChromeAutoHidePolicy()
        policy.observe(offset: 100)
        policy.observe(offset: 140) // hidden
        XCTAssertEqual(policy.observe(offset: 5), .shown,
                       "landing near the top reveals regardless of direction history")
    }

    func testRubberBandNegativeOffsetShows() {
        var policy = ChromeAutoHidePolicy()
        policy.observe(offset: 100)
        policy.observe(offset: 140) // hidden
        XCTAssertEqual(policy.observe(offset: -12), .shown)
    }

    func testDirectionFlipResetsAccumulation() {
        var policy = ChromeAutoHidePolicy()
        policy.observe(offset: 100)
        policy.observe(offset: 120) // down 20, under threshold
        policy.observe(offset: 115) // up 5 — resets the downward run
        policy.observe(offset: 135) // down 20 again, still under threshold
        XCTAssertEqual(policy.chrome, .shown,
                       "no single downward run crossed the threshold")
        XCTAssertEqual(policy.observe(offset: 145), .hidden,
                       "another 10pt completes a 30pt downward run")
    }

    func testJitterDoesNotFlap() {
        var policy = ChromeAutoHidePolicy()
        policy.observe(offset: 200)
        policy.observe(offset: 260) // hidden
        for offset in [258.0, 261, 259, 262, 260, 258] {
            XCTAssertEqual(policy.observe(offset: offset), .hidden,
                           "±3pt of jitter must not reveal (offset \(offset))")
        }
    }
}
