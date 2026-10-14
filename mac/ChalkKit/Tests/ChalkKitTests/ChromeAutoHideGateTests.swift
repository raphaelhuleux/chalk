import XCTest
@testable import ChalkKit

/// What the shell does with the scroll policy's answer. The policy says where
/// the reader is going; the gate says whether the chrome is allowed to react —
/// zen owns visibility outright, the preference can pin the chrome, and a
/// pointer resting in the top band (Mac) always wins over a stale hide.
final class ChromeAutoHideGateTests: XCTestCase {
    func testZenLeavesChromeUnmanaged() {
        XCTAssertEqual(
            ChromeAutoHideGate.decide(
                enabled: true, isZen: true, pointerInTopBand: false, scroll: .hidden),
            .unmanaged,
            "zen hides the chrome itself; auto-hide must not fight it")
    }

    func testZenLeavesChromeUnmanagedEvenWhenDisabled() {
        XCTAssertEqual(
            ChromeAutoHideGate.decide(
                enabled: false, isZen: true, pointerInTopBand: false, scroll: .shown),
            .unmanaged,
            "the preference governs auto-hide, not zen's own chrome")
    }

    func testDisabledPreferencePinsChromeShown() {
        XCTAssertEqual(
            ChromeAutoHideGate.decide(
                enabled: false, isZen: false, pointerInTopBand: false, scroll: .hidden),
            .shown,
            "with auto-hide off the tabs stay put no matter how far the reader scrolls")
    }

    func testPointerInTopBandReveals() {
        XCTAssertEqual(
            ChromeAutoHideGate.decide(
                enabled: true, isZen: false, pointerInTopBand: true, scroll: .hidden),
            .shown,
            "a mouse user reaching for a tab must not have to scroll up first")
    }

    func testScrolledAwayHides() {
        XCTAssertEqual(
            ChromeAutoHideGate.decide(
                enabled: true, isZen: false, pointerInTopBand: false, scroll: .hidden),
            .hidden)
    }

    func testScrolledBackShows() {
        XCTAssertEqual(
            ChromeAutoHideGate.decide(
                enabled: true, isZen: false, pointerInTopBand: false, scroll: .shown),
            .shown)
    }
}
