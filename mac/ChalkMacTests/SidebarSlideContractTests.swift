import XCTest
import ChalkKit
@testable import ChalkMac

/// docs/motion.md "Sidebar show/hide", the testable half. The slide itself is
/// visual; what a test can pin is the t=0 facts (the surface frozen and
/// purely translated over a snapped placement), the single covered reflow at
/// the end, the guaranteed release under a dead snapshotter, that a rapid
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
        UIState(window: .windowed, sidebar: .hidden, mode: .normal, appearance: .light)
    }

    private var shownState: UIState {
        UIState(window: .windowed, sidebar: .shown, mode: .normal, appearance: .light)
    }

    /// A settled root with the Library hidden, on the animated lane.
    private func makeRoot() -> RootSplitViewController {
        let root = host.makeRoot(for: hiddenState)
        host.settleToFixedPoint(root, state: hiddenState)
        return root
    }

    private func makeShownRoot() -> RootSplitViewController {
        let root = host.makeRoot(for: shownState)
        host.settleToFixedPoint(root, state: shownState)
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
    func testTheSlideTransformDoesNotStandOnTheEditor() throws {
        let root = makeShownRoot()
        let editorView = root.editorForTesting.view
        XCTAssertFalse(editorView.isDescendant(of: root.sidebarColumnForTesting),
                       "the slide transforms this view; the editor must not be inside it")
        XCTAssertTrue(root.sidebarForTesting.view.isDescendant(of: root.sidebarColumnForTesting))
    }

    /// The hide posts the chips' TARGET inset at slide start and lands the
    /// placement only in its completion, so a layout pass in between measures
    /// the old, still-tiled divider. Posting that would jump the chips back
    /// mid-slide.
    func testALayoutPassMidHideDoesNotRepostTheDivider() throws {
        try XCTSkipIf(TestAccessibility.isReduceMotionEnabled,
                      "Reduce Motion routes to the instant branch")
        let root = makeShownRoot()
        injectFastSettle(on: root)
        XCTAssertGreaterThan(root.stripLeadingInsetForTesting, 0,
                             "precondition: the chips sit past the divider")

        root.cmdToggleSidebar()
        XCTAssertEqual(root.stripLeadingInsetForTesting, 0, accuracy: 0.5,
                       "the target is posted at slide start")
        root.view.needsLayout = true
        root.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(root.stripLeadingInsetForTesting, 0, accuracy: 0.5,
                       "a layout pass the slide owns re-posted the divider")

        pumpUntilSettled(root)
        XCTAssertEqual(root.stripLeadingInsetForTesting, 0, accuracy: 0.5)
    }

    /// The behavioural twin: during an animated hide the editor column must
    /// stay where it is. Only the Library moves.
    func testAnimatedHideDoesNotDragTheEditorColumn() throws {
        try XCTSkipIf(TestAccessibility.isReduceMotionEnabled,
                      "Reduce Motion routes to the instant branch")
        let root = makeShownRoot()
        injectFastSettle(on: root)
        let editorView = root.editorForTesting.view
        let before = root.view.convert(editorView.bounds, from: editorView)

        root.cmdToggleSidebar()
        let during = root.view.convert(editorView.bounds, from: editorView)
        XCTAssertEqual(during.minX, before.minX, accuracy: 0.5,
                       "the editor column must not be translated by the Library's slide")
        XCTAssertFalse(CATransform3DIsIdentity(root.sidebarColumnForTesting.layer?.transform ?? CATransform3DIdentity),
                       "the Library column is what slides")

        pumpUntilSettled(root)
    }

    // MARK: - the hide lane's end state

    /// The ANIMATED hide must land in the same state the instant hide does.
    func testAnimatedHideLeavesTheSameStateTheInstantHideDoes() throws {
        try XCTSkipIf(TestAccessibility.isReduceMotionEnabled,
                      "Reduce Motion routes to the instant branch")
        let root = makeShownRoot()
        injectFastSettle(on: root)
        XCTAssertTrue(root.isSidebarVisible, "precondition: the Library is showing")

        root.cmdToggleSidebar()
        pumpUntilSettled(root)

        XCTAssertFalse(root.isSidebarVisible, "the animated hide must actually hide the Library")
        XCTAssertNil(root.chromeLayout(for: hiddenState).libraryPanel)
        XCTAssertTrue(CATransform3DIsIdentity(root.sidebarColumnForTesting.layer?.transform ?? CATransform3DIdentity),
                      "the slide leaves no transform behind")
    }

    /// And the Library must come back afterwards.
    func testShowAfterAnAnimatedHideBringsTheLibraryBack() throws {
        try XCTSkipIf(TestAccessibility.isReduceMotionEnabled,
                      "Reduce Motion routes to the instant branch")
        let root = makeShownRoot()
        injectFastSettle(on: root)

        root.cmdToggleSidebar()          // hide
        pumpUntilSettled(root)
        root.cmdToggleSidebar()          // show again
        pumpUntilSettled(root)

        XCTAssertTrue(root.isSidebarVisible, "the Library must come back after an animated hide")
        XCTAssertNotNil(root.chromeLayout(for: shownState).libraryPanel)
    }

    // MARK: - t=0 facts

    func testSlideStartSnapsThePlacementAndFreezesTheTranslatedSurface() throws {
        try XCTSkipIf(TestAccessibility.isReduceMotionEnabled,
                      "Reduce Motion routes to the instant branch; the t=0 facts are about the animated lane")
        let root = makeRoot()
        injectFastSettle(on: root)
        let boundsBefore = root.editorForTesting.contentViewBoundsForTesting

        root.applyTransitionForTesting(.sidebar(true))

        // Same turn, nothing settled: the placement is already snapped, the
        // surface is width-frozen and purely translated, and its bounds have
        // not changed; the webview never reflows mid-motion.
        XCTAssertTrue(root.isSidebarVisible,
                      "the placement snaps at slide START, not at the end")
        XCTAssertTrue(root.editorForTesting.isContentWidthFrozenForTesting,
                      "the surface's width must be frozen for the whole slide")
        XCTAssertFalse(root.editorForTesting.contentTransformForTesting.isIdentity,
                       "the visible motion is a pure translation of the frozen surface")
        XCTAssertEqual(root.editorForTesting.contentViewBoundsForTesting.size.width,
                       boundsBefore.size.width, accuracy: 0.5,
                       "the surface's bounds must not change at slide start; that reflow is the flicker")
        let postedInset = root.stripLeadingInsetForTesting
        XCTAssertGreaterThan(postedInset, 0, "the chips' target is posted with the snap")

        pumpUntilSettled(root)
        XCTAssertFalse(root.editorForTesting.isContentWidthFrozenForTesting,
                       "the slide must end released")
        XCTAssertEqual(root.stripLeadingInsetForTesting, postedInset, accuracy: 0.5,
                       "the settle lands on the inset the snap posted")
    }

    // MARK: - One reflow, onto the fresh layout

    func testSettleReflowsExactlyOnceOntoTheFreshLayout() throws {
        try XCTSkipIf(TestAccessibility.isReduceMotionEnabled)
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
                       "one transition, one reflow: the settle releases exactly once")

        let reached = root.chromeLayout(for: shown)
        func expectClose(_ name: String, _ a: CGRect, _ b: CGRect) {
            XCTAssertTrue(abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
                            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1,
                          "\(name): reached=\(a) fresh=\(b); the slide must land on the fresh layout")
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
        try XCTSkipIf(TestAccessibility.isReduceMotionEnabled)
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
        try XCTSkipIf(TestAccessibility.isReduceMotionEnabled)
        let root = makeRoot()
        var held: [(NSImage?) -> Void] = []
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
        // canceled settle must discard it. Releasing here would unfreeze the
        // surface mid-slide, exactly the flicker the freeze prevents.
        held[0](nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(root.editorForTesting.isContentWidthFrozenForTesting,
                      "a stale snapshot answer must not release the NEW slide's freeze")

        pumpUntilSettled(root)
        XCTAssertFalse(root.isSidebarTransitionInFlightForTesting)
        XCTAssertFalse(root.editorForTesting.isContentWidthFrozenForTesting)
        XCTAssertFalse(root.isSidebarVisible)
        // cancel released slide 1's freeze once, slide 2's settle released
        // its own once; the stale answer released nothing.
        XCTAssertEqual(root.editorForTesting.reflowCountForTesting, reflowsBefore + 2,
                       "the cancel releases slide 1 once; slide 2 settles once; nothing else may release")
    }

    // MARK: - The divider drag

    /// Dragging the divider resizes the column live and persists the width on
    /// release, within the resizable range.
    func testDraggingTheDividerPersistsTheWidth() throws {
        let root = makeShownRoot()
        XCTAssertFalse(root.sidebarResizeGripIsHiddenForTesting, "the grip shows with the Library")
        XCTAssertEqual(root.sidebarResizeGripFrameForTesting.midX, Self.pinnedSidebarWidth, accuracy: 1,
                       "the grip straddles the divider")
        root.resizeSidebarForTesting(to: 340)
        XCTAssertEqual(root.chromeLayout(for: shownState).libraryPanel?.width ?? -1, 340, accuracy: 1)
        XCTAssertEqual(Preferences.sidebarWidth, 340, accuracy: 1)
        root.resizeSidebarForTesting(to: 10)
        XCTAssertEqual(Preferences.sidebarWidth, Preferences.sidebarWidthRange.lowerBound, accuracy: 1,
                       "the drag clamps to the range")
        root.applyTransitionForTesting(.sidebar(false))
        pumpUntilSettled(root)
        XCTAssertTrue(root.sidebarResizeGripIsHiddenForTesting, "no Library, no grip")
    }
}
