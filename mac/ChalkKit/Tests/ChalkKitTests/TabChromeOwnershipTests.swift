import XCTest
@testable import ChalkKit

/// Ownership of the tab row, and the handover rule that keeps a chrome's
/// hidden state from outliving its turn.
///
/// Keeping the decision here (UIKit-free Foundation) is what makes it
/// testable without a window: the view controller is left with nothing but
/// the application of these answers.
final class TabChromeOwnershipTests: XCTestCase {
    private func owner(
        fullScreen: Bool = false, zen: Bool = false, glue: Bool = true
    ) -> TabChromeOwner {
        TabChromeOwnership.owner(
            isMacFullScreen: fullScreen, isZen: zen, glueAvailable: glue)
    }

    // MARK: - Ownership

    func testWindowedMacWithGlueGivesTheTabsToTheTitlebarStrip() {
        XCTAssertEqual(owner(), .appKitStrip)
    }

    func testFullScreenGivesTheTabsToTheUIKitBand() {
        // The glue hides the system toolbar in full screen (its full-screen
        // host paints an opaque band), so the app's own band is the tab UI.
        XCTAssertEqual(owner(fullScreen: true), .uiKitBand)
    }

    func testNoGlueFallsBackToTheUIKitBandInBothWindowStates() {
        XCTAssertEqual(owner(glue: false), .uiKitBand)
        XCTAssertEqual(owner(fullScreen: true, glue: false), .uiKitBand)
    }

    func testZenOutranksEveryOtherInput() {
        for fullScreen in [false, true] {
            for glue in [false, true] {
                XCTAssertEqual(
                    owner(fullScreen: fullScreen, zen: true, glue: glue), .none,
                    "zen shows no tab row (fullScreen=\(fullScreen) glue=\(glue))")
            }
        }
    }

    // MARK: - The handover rule

    func testOnlyTheOwnerMayBeLeftHidden() {
        let band = TabChromeOwnership.autoHideApplication(
            owner: .uiKitBand, autoHidden: true)
        XCTAssertTrue(band.bandHidden)
        XCTAssertFalse(band.stripFaded, "a chrome that owns nothing is never left faded")

        let strip = TabChromeOwnership.autoHideApplication(
            owner: .appKitStrip, autoHidden: true)
        XCTAssertTrue(strip.stripFaded)
        XCTAssertFalse(strip.bandHidden, "the band must not keep a slide-out transform")
    }

    func testShownStateResetsBothChromesOutsideZen() {
        for owner in [TabChromeOwner.uiKitBand, .appKitStrip] {
            let applied = TabChromeOwnership.autoHideApplication(
                owner: owner, autoHidden: false)
            XCTAssertEqual(applied, ChromeAutoHideApplication(
                bandHidden: false, stripFaded: false))
        }
    }

    func testZenRestsWithTheStripFaded() {
        // Zen owns visibility outright. The band must never keep a slide-out
        // transform into zen — but the STRIP's zen state IS the fade, so
        // every re-application (ownership handovers included) must keep it
        // faded, not "reset" it visible over a zen window.
        for autoHidden in [false, true] {
            let applied = TabChromeOwnership.autoHideApplication(
                owner: .none, autoHidden: autoHidden)
            XCTAssertEqual(applied, ChromeAutoHideApplication(
                bandHidden: false, stripFaded: true), "autoHidden=\(autoHidden)")
        }
    }

    /// The regression itself, as a sequence: hide the chrome in full screen,
    /// leave full screen, come back. The band must not still be translated
    /// offscreen when it wins the tabs back.
    func testLeavingAndReenteringFullScreenClearsTheBandsStaleTransform() {
        let autoHidden = true

        let inFullScreen = TabChromeOwnership.autoHideApplication(
            owner: owner(fullScreen: true), autoHidden: autoHidden)
        XCTAssertTrue(inFullScreen.bandHidden, "the band is the tab UI and hides")

        let windowed = TabChromeOwnership.autoHideApplication(
            owner: owner(fullScreen: false), autoHidden: autoHidden)
        XCTAssertFalse(windowed.bandHidden,
                       "leaving full screen must CLEAR the band, not merely hide it")
        XCTAssertTrue(windowed.stripFaded,
                      "and the state moves to the chrome that now owns the tabs")

        let backInFullScreen = TabChromeOwnership.autoHideApplication(
            owner: owner(fullScreen: true), autoHidden: autoHidden)
        XCTAssertTrue(backInFullScreen.bandHidden)
        XCTAssertFalse(backInFullScreen.stripFaded)
    }
}
