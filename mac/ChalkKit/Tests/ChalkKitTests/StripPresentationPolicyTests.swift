import XCTest
@testable import ChalkKit

/// The two writers of the titlebar strip's `isHidden`, and the two bugs that
/// live in their interaction. Both directions are pinned, because only one of
/// them was guarded before 2026-08-24.
final class StripPresentationPolicyTests: XCTestCase {
    private func resolve(chromeVisible: Bool, chipsFaded: Bool) -> StripPresentation {
        StripPresentationPolicy.resolve(chromeVisible: chromeVisible, chipsFaded: chipsFaded)
    }

    func testTheRestingWindowedStateShowsTheChips() {
        XCTAssertEqual(resolve(chromeVisible: true, chipsFaded: false),
                       StripPresentation(isHidden: false, alpha: 1))
    }

    /// The reported bug: un-fading must not resurrect a strip whose chrome is
    /// hidden. Full screen hides the chrome, then the ownership re-application
    /// posts `faded: false` — and the strip reappeared in the revealed system
    /// titlebar as a second tab row above the app's band.
    func testUnfadingDoesNotUnhideHiddenChrome() {
        XCTAssertTrue(resolve(chromeVisible: false, chipsFaded: false).isHidden)
    }

    /// The mirror case, which the glue already guarded: showing the chrome
    /// (a full-screen exit restores the toolbar unconditionally) must not make
    /// alpha-0 chips clickable over a zen window.
    func testShowingChromeDoesNotUnhideFadedChips() {
        let presentation = resolve(chromeVisible: true, chipsFaded: true)
        XCTAssertTrue(presentation.isHidden)
        XCTAssertEqual(presentation.alpha, 0)
    }

    func testHiddenAndFadedStaysHidden() {
        XCTAssertTrue(resolve(chromeVisible: false, chipsFaded: true).isHidden)
    }

    /// Alpha belongs to the fade alone: a hidden-chrome strip is not "faded",
    /// so when its chrome comes back it must come back at full strength rather
    /// than at whatever the last fade left behind.
    func testOnlyTheFadeChangesAlpha() {
        XCTAssertEqual(resolve(chromeVisible: false, chipsFaded: false).alpha, 1)
        XCTAssertEqual(resolve(chromeVisible: true, chipsFaded: false).alpha, 1)
        XCTAssertEqual(resolve(chromeVisible: false, chipsFaded: true).alpha, 0)
        XCTAssertEqual(resolve(chromeVisible: true, chipsFaded: true).alpha, 0)
    }

    /// Every invisible state is also hidden: AppKit hit-tests alpha-0 views, so
    /// "invisible but clickable" is a bug in every combination.
    func testNothingIsInvisibleAndStillClickable() {
        for chromeVisible in [true, false] {
            for chipsFaded in [true, false] {
                let presentation = resolve(chromeVisible: chromeVisible, chipsFaded: chipsFaded)
                if presentation.alpha == 0 {
                    XCTAssertTrue(presentation.isHidden,
                                  "alpha 0 with isHidden false takes clicks nobody can see")
                }
            }
        }
    }
}
