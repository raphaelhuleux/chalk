import XCTest
@testable import ChalkKit

/// The pure oracle for the windowed Mac titlebar strip: what the app's three
/// glue posts (divider inset, visibility, fade) should add up to in each
/// resting state. Sibling of TabChromeOwnershipTests — the ownership rule
/// says WHO carries the tabs, this says what the strip lane must look like.
final class MacStripExpectationTests: XCTestCase {

    func testWindowedNormalWithTheLibraryTiledInsetsToTheDivider() {
        let strip = MacStripExpectation.forState(
            window: .windowed, sidebar: .shown, mode: .normal,
            glueAvailable: true, dividerX: 350)
        XCTAssertEqual(strip, MacStripExpectation(dividerX: 350, visible: true, faded: false))
    }

    func testWindowedNormalWithoutTheLibraryRestsAtTheTrafficLights() {
        let strip = MacStripExpectation.forState(
            window: .windowed, sidebar: .hidden, mode: .normal,
            glueAvailable: true, dividerX: 0)
        XCTAssertEqual(strip.dividerX, 0)
        XCTAssertTrue(strip.visible)
    }

    /// Zen closes the Library whatever the sidebar dimension asked for, so
    /// the expectation must zero the inset itself rather than trust the
    /// caller to remember that product rule. On the FADE lane (the default,
    /// docs/motion.md "Zen / normal") the toolbar stays standing — the chips
    /// fade instead of the titlebar collapsing — so zen expects a VISIBLE,
    /// FADED strip resting at the traffic lights.
    func testZenOnTheFadeLaneKeepsTheToolbarAndFadesTheChips() {
        let strip = MacStripExpectation.forState(
            window: .windowed, sidebar: .shown, mode: .zen,
            glueAvailable: true, dividerX: 350)
        XCTAssertTrue(strip.visible, "the fade lane keeps the titlebar standing")
        XCTAssertTrue(strip.faded, "zen rests with the chips faded on the fade lane")
        XCTAssertEqual(strip.dividerX, 0, "zen closed the Library; a kept inset is stale")
    }

    /// Full screen hands the tab row to the UIKit band (TabChromeOwnership),
    /// so the titlebar strip is not visible — but the divider inset is still
    /// tracked, because leaving full screen must not land on a stale inset.
    func testFullscreenHandsTheTabsToTheBandButKeepsTrackingTheDivider() {
        let strip = MacStripExpectation.forState(
            window: .fullscreen, sidebar: .shown, mode: .normal,
            glueAvailable: true, dividerX: 350)
        XCTAssertFalse(strip.visible)
        XCTAssertEqual(strip.dividerX, 350)
    }

    func testNoGlueMeansNoStrip() {
        let strip = MacStripExpectation.forState(
            window: .windowed, sidebar: .hidden, mode: .normal,
            glueAvailable: false, dividerX: 0)
        XCTAssertFalse(strip.visible, "without the glue there is no strip to show")
    }

    /// Outside zen the fade is never on at rest, in any state: only a live
    /// auto-hide scroll run may fade the strip, and the matrix asserts
    /// resting states. Zen is the one exception — its resting titlebar IS
    /// the faded strip.
    func testOnlyZenRestsFaded() {
        for window in UIState.WindowMode.allCases {
            for sidebar in UIState.SidebarState.allCases {
                for mode in UIState.ChromeMode.allCases {
                    let strip = MacStripExpectation.forState(
                        window: window, sidebar: sidebar, mode: mode,
                        glueAvailable: true, dividerX: 350)
                    XCTAssertEqual(strip.faded, mode == .zen,
                                   "\(window)-\(sidebar)-\(mode)")
                }
            }
        }
    }
}
