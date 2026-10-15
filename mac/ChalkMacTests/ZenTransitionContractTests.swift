import XCTest
import ChalkKit
@testable import ChalkMac

/// docs/motion.md "Zen / normal" (C3), the testable half. The old zen toggle
/// snapped everything inside `performWithoutAnimation`; the contract is now:
/// the band and pill FADE over `motionStandard`, the Library leaves through
/// the one sidebar slide, the resting offset glides web-side on the same
/// clock, and the Mac titlebar strip takes the FADE lane. What a test can pin
/// is the t=0 facts (the slide engaged, the band not snapped away), the
/// settled equality with fresh layouts, the instant-lane/animated-lane end
/// states being identical, the recorded strip decisions matching
/// `MacStripExpectation`, and the glide request the editor container relayed.
///
/// Like `SidebarSlideContractTests`, the animated tests run the REAL lane
/// (`motionPolicyForTesting` stays `.system`) and wait out the clocks; the
/// injected snapshotter/paint-gate seams keep the slide's settle
/// deterministic.
@MainActor
final class ZenTransitionContractTests: XCTestCase {
    private var host: ChromeMatrixHost!

    /// Same pin as the transition matrix: fresh comparisons need the same
    /// sidebar width on both roots (the host restores the real value).
    private static let pinnedSidebarWidth: CGFloat = 300

    override func setUp() {
        super.setUp()
        host = ChromeMatrixHost()
        Preferences.sidebarWidth = Self.pinnedSidebarWidth
    }

    override func tearDown() {
        host.restoreAndDismantle()
        host = nil
        super.tearDown()
    }

    /// Full screen: the band is the only chrome above the text there, so zen
    /// changes the resting line (windowed, the system titlebar still
    /// reserves and the line stays put), and the Library is open so the close
    /// has something to do.
    private var bandState: UIState {
        return UIState(window: .fullscreen, sidebar: .shown,
                       mode: .normal, appearance: .light)
    }

    private func pump(upTo seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// Wait out the slide (and its settle), then the band/pill fade clock.
    private func pumpUntilZenSettled(_ root: RootSplitViewController) {
        pump(upTo: 3.0) {
            !root.isSidebarTransitionInFlightForTesting
                && !root.editorForTesting.isContentWidthFrozenForTesting
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: ChalkMetrics.motionStandard + 0.15))
    }

    /// Instant snapshot/paint seams for the sidebar slide's settle.
    private func injectFastSettle(on root: RootSplitViewController) {
        root.sidebarSnapshotterForTesting = { done in
            DispatchQueue.main.async { done(nil) }
        }
        root.sidebarPaintGateForTesting = { ready in
            DispatchQueue.main.async { ready() }
        }
    }

    /// Field-subset comparison against a fresh layout, 1pt tolerance — the
    /// same shape as `SidebarSlideContractTests`.
    private func assertMatchesFresh(_ reached: ChromeLayout, _ fresh: ChromeLayout,
                                    _ label: String) {
        func close(_ name: String, _ a: CGRect, _ b: CGRect) {
            XCTAssertTrue(abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
                            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1,
                          "\(label) \(name): reached=\(a) fresh=\(b)")
        }
        close("band", reached.band, fresh.band)
        close("tabStrip", reached.tabStrip, fresh.tabStrip)
        close("editorContent", reached.editorContent, fresh.editorContent)
        close("footerPill", reached.footerPill, fresh.footerPill)
        XCTAssertEqual(reached.editorRestingTop, fresh.editorRestingTop, accuracy: 1.0,
                       "\(label): the resting line must land exactly where a fresh root rests")
        XCTAssertEqual(reached.reserveTop, fresh.reserveTop, accuracy: 1.0, label)
        switch (reached.macStrip, fresh.macStrip) {
        case (nil, nil): break
        case let (a?, b?):
            XCTAssertEqual(a.visible, b.visible, "\(label) strip visibility")
            XCTAssertEqual(a.faded, b.faded, "\(label) strip fade")
            XCTAssertEqual(a.dividerX, b.dividerX, accuracy: 1.0, "\(label) strip inset")
        default:
            XCTFail("\(label) macStrip: reached=\(String(describing: reached.macStrip)) "
                    + "fresh=\(String(describing: fresh.macStrip))")
        }
    }

    // MARK: - t=0 facts (the glide, not the snap)

    func testAnimatedZenEnterSlidesTheLibraryOutAndFadesTheBand() throws {
        try XCTSkipIf(TestAccessibility.isReduceMotionEnabled,
                      "Reduce Motion takes the instant placement; the t=0 facts are about the animated lane")
        let root = host.makeRoot(for: bandState)
        injectFastSettle(on: root)
        host.settleToFixedPoint(root, state: bandState)
        XCTAssertFalse(root.isHeaderHiddenForTesting,
                       "the start state must show the band, or the fade proves nothing")

        root.applyTransitionForTesting(.zen(true))

        // Same turn: the band is fading, not snapped away.
        XCTAssertFalse(root.isHeaderHiddenForTesting,
                       "the band fades over motionStandard; isHidden lands in the fade's completion")

        pumpUntilZenSettled(root)
        XCTAssertTrue(root.isHeaderHiddenForTesting,
                      "the fade must land the identical final state the snap used to")
        XCTAssertFalse(root.isSidebarTransitionInFlightForTesting)
    }

    // MARK: - Settled equality with fresh layouts

    func testAnimatedZenRoundTripLandsOnTheFreshLayouts() throws {
        try XCTSkipIf(TestAccessibility.isReduceMotionEnabled)
        let start = bandState
        let zenState = start.applying(.zen(true))
        let exitState = zenState.applying(.zen(false))

        // Fresh oracles FIRST: building one re-points the host window's root.
        let freshZenRoot = host.makeRoot(for: zenState)
        freshZenRoot.motionPolicyForTesting = .instant
        host.settleToFixedPoint(freshZenRoot, state: zenState)
        let freshZen = freshZenRoot.chromeLayout(for: zenState)
        let freshExitRoot = host.makeRoot(for: exitState)
        freshExitRoot.motionPolicyForTesting = .instant
        host.settleToFixedPoint(freshExitRoot, state: exitState)
        let freshExit = freshExitRoot.chromeLayout(for: exitState)

        let root = host.makeRoot(for: start)
        injectFastSettle(on: root)
        host.settleToFixedPoint(root, state: start)

        root.applyTransitionForTesting(.zen(true))
        pumpUntilZenSettled(root)
        host.settleToFixedPoint(root, state: zenState)
        assertMatchesFresh(root.chromeLayout(for: zenState), freshZen, "zen enter")

        root.applyTransitionForTesting(.zen(false))
        pumpUntilZenSettled(root)
        host.settleToFixedPoint(root, state: exitState)
        assertMatchesFresh(root.chromeLayout(for: exitState), freshExit, "zen exit")
    }

    // MARK: - Instant lane lands the animated lane's end state

    func testInstantZenLandsTheSameEndStateAsTheAnimatedLane() throws {
        try XCTSkipIf(TestAccessibility.isReduceMotionEnabled)
        let start = bandState
        let zenState = start.applying(.zen(true))

        let animatedRoot = host.makeRoot(for: start)
        injectFastSettle(on: animatedRoot)
        host.settleToFixedPoint(animatedRoot, state: start)
        animatedRoot.applyTransitionForTesting(.zen(true))
        pumpUntilZenSettled(animatedRoot)
        host.settleToFixedPoint(animatedRoot, state: zenState)
        let animated = animatedRoot.chromeLayout(for: zenState)
        let animatedBandHidden = animatedRoot.isHeaderHiddenForTesting

        let instantRoot = host.makeRoot(for: start)
        instantRoot.motionPolicyForTesting = .instant
        host.settleToFixedPoint(instantRoot, state: start)
        instantRoot.applyTransitionForTesting(.zen(true))
        host.settleToFixedPoint(instantRoot, state: zenState)
        let instant = instantRoot.chromeLayout(for: zenState)

        XCTAssertEqual(animatedBandHidden, instantRoot.isHeaderHiddenForTesting,
                       "both lanes must land the same band presence")
        assertMatchesFresh(animated, instant, "animated vs instant")
        XCTAssertEqual(animated.editorRestingTop, instant.editorRestingTop, accuracy: 0.5,
                       "the recorded resting inset must not depend on the lane")
    }

    // MARK: - The chrome-top glide request

    func testZenAsksTheActiveSurfaceToGlideTheChromeTop() throws {
        try XCTSkipIf(TestAccessibility.isReduceMotionEnabled)
        let root = host.makeRoot(for: bandState)
        injectFastSettle(on: root)
        host.settleToFixedPoint(root, state: bandState)
        root.editorForTesting.chromeTopChangeTrailForTesting.removeAll()

        root.applyTransitionForTesting(.zen(true))
        pumpUntilZenSettled(root)

        let glides = root.editorForTesting.chromeTopChangeTrailForTesting
        guard let entered = glides.first else {
            return XCTFail("entering zen reclaims the band, so the chrome-top must change; trail=\(glides)")
        }
        XCTAssertEqual(entered.duration ?? -1, ChalkMetrics.motionStandard, accuracy: 0.001,
                       "the glide rides zen's motionStandard clock (docs/motion.md C3); trail=\(glides)")

        // The instant lane must ask for NO glide — placement, not motion.
        let instantRoot = host.makeRoot(for: bandState)
        instantRoot.motionPolicyForTesting = .instant
        host.settleToFixedPoint(instantRoot, state: bandState)
        instantRoot.editorForTesting.chromeTopChangeTrailForTesting.removeAll()
        instantRoot.applyTransitionForTesting(.zen(true))
        host.settleToFixedPoint(instantRoot, state: bandState.applying(.zen(true)))
        let snaps = instantRoot.editorForTesting.chromeTopChangeTrailForTesting
        XCTAssertFalse(snaps.isEmpty, "the instant lane still changes the inset")
        XCTAssertTrue(snaps.allSatisfy { $0.duration == nil },
                      "instant placement never asks the surface to animate; trail=\(snaps)")
    }
}
