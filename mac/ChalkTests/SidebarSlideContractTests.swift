import XCTest
import ChalkKit
@testable import Chalk

/// docs/motion.md "Sidebar show/hide", the testable half. The slide itself is
/// visual; what a test can pin is the t=0 facts (the surface frozen and
/// purely translated over a snapped display mode), the single covered reflow
/// at the end, the guaranteed release under a dead snapshotter, that a rapid
/// re-toggle cancels the pending release, and that the settled layout is the
/// layout a fresh root shows.
///
/// These tests run the REAL animated lane (`motionPolicyForTesting` stays
/// `.system`), so each one waits out the `motionSidebar` clock plus the
/// settle backstops; the injected snapshotter/paint-gate seams keep the async
/// half deterministic.
@MainActor
final class SidebarSlideContractTests: XCTestCase {
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

    private var hiddenState: UIState {
        UIState(window: .windowed,
                sidebar: .hidden, mode: .normal, appearance: .light)
    }

    /// A settled root with the Library hidden, on the animated lane.
    private func makeRoot() -> RootSplitViewController {
        let root = host.makeRoot(for: hiddenState)
        host.settleToFixedPoint(root, state: hiddenState)
        return root
    }

    /// Pump the runloop until `done`, or fail past `seconds`.
    private func pump(upTo seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private func pumpUntilSettled(_ root: RootSplitViewController, seconds: TimeInterval = 3.0) {
        pump(upTo: seconds) {
            !root.isSidebarTransitionInFlightForTesting
                && !root.editorForTesting.isContentWidthFrozenForTesting
        }
    }

    /// Instant snapshot/paint seams: the settle machinery runs in full, with
    /// no dependency on a real web process's timing.
    private func injectFastSettle(on root: RootSplitViewController) {
        root.sidebarSnapshotterForTesting = { done in
            DispatchQueue.main.async { done(nil) }
        }
        root.sidebarPaintGateForTesting = { ready in
            DispatchQueue.main.async { ready() }
        }
    }

    // MARK: - the slide must move the Library, and only the Library

    /// The transform that slides the Library must not stand on a view that
    /// also hosts the editor.
    ///
    /// Where both columns live inside ONE (the macOS 27 split view)
    /// `_UISplitViewControllerAdaptiveColumnContainerView` which is the split
    /// view's direct subview, so a walk that climbs until the parent IS the
    /// split view's view lands on the shared container. Transforming it drags
    /// the editor along. The show got away with it — its transform ends at
    /// `.identity`, so the end state is right — while the hide ends at
    /// `translate(-sidebarWidth)` and holds the editor a sidebar-width off
    /// screen for the whole slide. Reveal looked fine, hide did not.
    func testTheSlideTransformDoesNotStandOnTheEditor() throws {
        let shown = UIState(window: .windowed,
                            sidebar: .shown, mode: .normal, appearance: .light)
        let root = host.makeRoot(for: shown)
        host.settleToFixedPoint(root, state: shown)
        let editorView = try XCTUnwrap(root.editorForTesting.viewIfLoaded)
        let column = try XCTUnwrap(root.sidebarColumnContainerForTesting())
        XCTAssertFalse(editorView.isDescendant(of: column),
                       "the slide transforms this view; the editor must not be inside it")
    }

    /// The hide posts the titlebar strip's TARGET inset at slide start and
    /// snaps the display mode only in its completion, so a layout pass in
    /// between measures the old, still-tiled divider. Posting that would jump
    /// the chips back mid-slide.
    func testALayoutPassMidHideDoesNotRepostTheDivider() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled,
                      "Reduce Motion routes to the instant branch")
        let shown = UIState(window: .windowed,
                            sidebar: .shown, mode: .normal, appearance: .light)
        let root = host.makeRoot(for: shown)
        host.settleToFixedPoint(root, state: shown)
        injectFastSettle(on: root)

        root.cmdToggleSidebar()
        let pushes = root.stripLeadingInsetPushCountForTesting
        root.view.setNeedsLayout()
        root.view.layoutIfNeeded()
        XCTAssertEqual(root.stripLeadingInsetPushCountForTesting, pushes,
                       "a layout pass the slide owns re-posted the divider")
        XCTAssertEqual(root.lastStripDividerXForTesting, 0)

        pumpUntilSettled(root)
        XCTAssertGreaterThan(root.stripLeadingInsetPushCountForTesting, pushes,
                             "the completion pushes once the slide lets go")
        XCTAssertEqual(root.lastStripDividerXForTesting, 0)
    }

    /// The behavioural twin: during an animated hide the editor column must
    /// stay where it is. Only the Library moves.
    func testAnimatedHideDoesNotDragTheEditorColumn() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled,
                      "Reduce Motion routes to the instant branch")
        let shown = UIState(window: .windowed,
                            sidebar: .shown, mode: .normal, appearance: .light)
        let root = host.makeRoot(for: shown)
        host.settleToFixedPoint(root, state: shown)
        injectFastSettle(on: root)
        let editorView = try XCTUnwrap(root.editorForTesting.viewIfLoaded)
        let before = root.view.convert(editorView.bounds, from: editorView)

        root.cmdToggleSidebar()
        // Same turn: the animation's model values are already committed, so a
        // dragged editor shows up here without waiting on the clock.
        let during = root.view.convert(editorView.bounds, from: editorView)
        XCTAssertEqual(during.minX, before.minX, accuracy: 0.5,
                       "the editor column must not be translated by the Library's slide")

        pumpUntilSettled(root)
    }

    // MARK: - the hide lane's end state

    /// The ANIMATED hide must land in the same state the instant hide does.
    ///
    /// Nothing covered this before: every transition suite (the chrome matrix
    /// included) sets `motionPolicyForTesting = .instant`, and the instant
    /// branch calls `setSidebarVisible(false)`. Only the animated branch calls
    /// `hideSidebarColumn()`. So the animated hide is the one lane no test had
    /// ever run.
    func testAnimatedHideLeavesTheSameStateTheInstantHideDoes() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled,
                      "Reduce Motion routes to the instant branch")
        let shown = UIState(window: .windowed,
                            sidebar: .shown, mode: .normal, appearance: .light)
        let root = host.makeRoot(for: shown)
        host.settleToFixedPoint(root, state: shown)
        injectFastSettle(on: root)
        XCTAssertNotEqual(root.displayMode, .secondaryOnly, "precondition: the Library is showing")

        root.cmdToggleSidebar()
        pumpUntilSettled(root)

        XCTAssertEqual(root.displayMode, .secondaryOnly,
                       "the animated hide must actually hide the Library")
        XCTAssertEqual(root.preferredDisplayMode, .secondaryOnly,
                       "and must leave the PREFERENCE agreeing with it: a preference still "
                       + "saying .oneBesideSecondary is re-resolved by the next layout pass")
    }

    /// And the Library must come back afterwards. A hide that leaves the
    /// preference untouched makes the following show a no-op -- the preference
    /// is already the value `setSidebarVisible(true)` assigns, so the split
    /// view never re-lays out.
    func testShowAfterAnAnimatedHideBringsTheLibraryBack() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled,
                      "Reduce Motion routes to the instant branch")
        let shown = UIState(window: .windowed,
                            sidebar: .shown, mode: .normal, appearance: .light)
        let root = host.makeRoot(for: shown)
        host.settleToFixedPoint(root, state: shown)
        injectFastSettle(on: root)

        root.cmdToggleSidebar()          // hide
        pumpUntilSettled(root)
        root.cmdToggleSidebar()          // show again
        pumpUntilSettled(root)

        XCTAssertNotEqual(root.displayMode, .secondaryOnly,
                          "the Library must come back after an animated hide")
    }

    // MARK: - t=0 facts

    func testSlideStartSnapsTheModeAndFreezesTheTranslatedSurface() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled,
                      "Reduce Motion routes to the instant branch; the t=0 facts are about the animated lane")
        let root = makeRoot()
        injectFastSettle(on: root)
        let boundsBefore = root.editorForTesting.contentViewBoundsForTesting

        root.applyTransitionForTesting(.sidebar(true))

        // Same turn, nothing settled: the display mode is already snapped,
        // the surface is width-frozen and purely translated, and its bounds
        // have not changed — the webview never reflows mid-motion.
        XCTAssertNotEqual(root.displayMode, .secondaryOnly,
                          "the display mode snaps at slide START (performWithoutAnimation), not at the end")
        XCTAssertTrue(root.editorForTesting.isContentWidthFrozenForTesting,
                      "the surface's width must be frozen for the whole slide")
        XCTAssertFalse(root.editorForTesting.contentTransformForTesting.isIdentity,
                       "the visible motion is a pure translation of the frozen surface")
        XCTAssertEqual(root.editorForTesting.contentViewBoundsForTesting.size.width,
                       boundsBefore.size.width, accuracy: 0.5,
                       "the surface's bounds must not change at slide start — that reflow is the flicker")

        pumpUntilSettled(root)
        XCTAssertFalse(root.editorForTesting.isContentWidthFrozenForTesting,
                       "the slide must end released")
    }

    // MARK: - One reflow, onto the fresh layout

    func testSettleReflowsExactlyOnceOntoTheFreshLayout() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        let shown = hiddenState.applying(.sidebar(true))
        // Fresh oracle FIRST: building it re-points the host window's root.
        let freshRoot = host.makeRoot(for: shown)
        freshRoot.motionPolicyForTesting = .instant
        host.settleToFixedPoint(freshRoot, state: shown)
        let fresh = freshRoot.chromeLayout(for: shown)

        let root = makeRoot()
        injectFastSettle(on: root)
        let reflowsBefore = root.editorForTesting.reflowCountForTesting

        root.applyTransitionForTesting(.sidebar(true))
        pumpUntilSettled(root)
        host.settleToFixedPoint(root, state: shown)

        XCTAssertEqual(root.editorForTesting.reflowCountForTesting, reflowsBefore + 1,
                       "one transition, one reflow — the settle releases exactly once")

        let reached = root.chromeLayout(for: shown)
        func expectClose(_ name: String, _ a: CGRect, _ b: CGRect) {
            XCTAssertTrue(abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
                            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1,
                          "\(name): reached=\(a) fresh=\(b) — the slide must land on the fresh layout")
        }
        expectClose("editorContent", reached.editorContent, fresh.editorContent)
        expectClose("band", reached.band, fresh.band)
        expectClose("tabStrip", reached.tabStrip, fresh.tabStrip)
        expectClose("footerPill", reached.footerPill, fresh.footerPill)
        switch (reached.libraryPanel, fresh.libraryPanel) {
        case let (a?, b?): expectClose("libraryPanel", a, b)
        case (nil, nil): XCTFail("the shown state must have a Library panel")
        default: XCTFail("libraryPanel: reached=\(String(describing: reached.libraryPanel)) fresh=\(String(describing: fresh.libraryPanel))")
        }
        XCTAssertEqual(reached.reserveTop, fresh.reserveTop, accuracy: 1.0)
        XCTAssertEqual(reached.editorRestingTop, fresh.editorRestingTop, accuracy: 1.0)
    }

    // MARK: - Guaranteed release

    func testDeadSnapshotterStillReleasesOnTheBackstop() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        let root = makeRoot()
        // A snapshotter that never answers: the pre-armed release must still
        // unfreeze the width (as a covered reflow) on the backstop clock.
        root.sidebarSnapshotterForTesting = { _ in }
        root.sidebarPaintGateForTesting = { ready in
            DispatchQueue.main.async { ready() }
        }

        root.applyTransitionForTesting(.sidebar(true))
        pumpUntilSettled(root)

        XCTAssertFalse(root.editorForTesting.isContentWidthFrozenForTesting,
                       "a dead snapshotter must degrade to a covered reflow, never a stuck width")
        XCTAssertFalse(root.isSidebarTransitionInFlightForTesting,
                       "the settle must fully wind down on its backstops")
    }

    // MARK: - Rapid re-toggle

    func testRapidReToggleCancelsThePendingRelease() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        let root = makeRoot()
        var held: [(UIImage?) -> Void] = []
        root.sidebarSnapshotterForTesting = { done in held.append(done) }
        root.sidebarPaintGateForTesting = { ready in
            DispatchQueue.main.async { ready() }
        }
        let reflowsBefore = root.editorForTesting.reflowCountForTesting

        // Slide 1 (show) runs to its settle, whose snapshot we hold hostage.
        root.applyTransitionForTesting(.sidebar(true))
        pump(upTo: 2.0) { held.count == 1 }
        XCTAssertEqual(held.count, 1, "slide 1's settle must have asked for its snapshot")
        XCTAssertTrue(root.editorForTesting.isContentWidthFrozenForTesting,
                      "the width stays frozen while the settle waits")

        // Slide 2 (hide) lands mid-settle: it must cancel slide 1's pending
        // release and own the surface from here.
        root.applyTransitionForTesting(.sidebar(false))
        XCTAssertTrue(root.editorForTesting.isContentWidthFrozenForTesting,
                      "slide 2 freezes the surface for its own motion")

        // The hostage answers LATE, while slide 2 is still mid-flight: the
        // canceled settle must discard it — releasing here would unfreeze
        // the surface mid-slide, exactly the flicker the freeze prevents.
        held[0](nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(root.editorForTesting.isContentWidthFrozenForTesting,
                      "a stale snapshot answer must not release the NEW slide's freeze")

        pumpUntilSettled(root)
        XCTAssertFalse(root.isSidebarTransitionInFlightForTesting)
        XCTAssertFalse(root.editorForTesting.isContentWidthFrozenForTesting)
        // cancel released slide 1's freeze once, slide 2's settle released
        // its own once; the stale answer released nothing.
        XCTAssertEqual(root.editorForTesting.reflowCountForTesting, reflowsBefore + 2,
                       "the cancel releases slide 1 once; slide 2 settles once; nothing else may release")
    }
}
