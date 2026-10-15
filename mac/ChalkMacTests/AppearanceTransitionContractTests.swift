import XCTest
import ChalkKit
@testable import ChalkMac

/// docs/motion.md "Appearance" (C4): a theme change is a COVERED transition —
/// snapshot the active surface (old colors), install an opaque cover over the
/// webview's rect, then in ONE turn flip the trait, push `data-theme`, and
/// cross-dissolve the native chrome; the cover leaves only after the page has
/// committed a paint of the new colors (two in-page rAFs, backstopped).
/// Never a frame of new native chrome over old page colors that the cover
/// does not own.
///
/// The ordering probe drives the injected snapshotter/paint-gate seams (the
/// WebPaintGate pattern the sidebar slide proved) and reads the DEBUG event
/// trail; the gates make the async half deterministic. Reduce Motion cannot
/// be toggled from a test, so the `.instant` policy stands in for it: the
/// SAME branch (zero-duration fades, cover kept — the mismatch flash is
/// correctness, not motion).
@MainActor
final class AppearanceTransitionContractTests: XCTestCase {
    private var window: NSWindow!
    private var root: RootSplitViewController!
    private var incomingTheme: ThemePreference!
    private var incomingColorTheme: ChalkTheme!

    override func setUp() {
        super.setUp()
        incomingTheme = Preferences.themePreference
        incomingColorTheme = Preferences.colorTheme
        Preferences.colorTheme = .ink
        // Normalize BEFORE the root exists: viewDidLoad applies the stored
        // preference, and on a machine whose real preference is non-Auto the
        // override would already sit at the target — every later flip in the
        // test would then be a no-op. (tearDown restores the real value.)
        Preferences.themePreference = .auto
        window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        window.isHidden = false
        root = RootSplitViewController()
                window.rootViewController = root
        root.loadViewIfNeeded()
        window.layoutIfNeeded()
        // The split view attaches its column views over a runloop turn, and
        // the covered path (deliberately) degrades to a direct apply while
        // the editor column is not yet window-hosted — a real theme toggle
        // always happens on a settled window, so settle first.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        window.layoutIfNeeded()
    }

    override func tearDown() {
        Preferences.themePreference = incomingTheme
        Preferences.colorTheme = incomingColorTheme
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        root = nil
        super.tearDown()
    }

    private func pump(upTo seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// Paint-gate answers held hostage by `injectSeams(holdGate: true)`, in
    /// ask order — one per transition, so a rapid-toggle test can answer the
    /// FIRST transition's gate specifically.
    private var heldGateAnswers: [() -> Void] = []

    /// Instant seams; the paint gate can be held by the caller.
    private func injectSeams(holdGate: Bool = false) {
        root.appearanceSnapshotterForTesting = { done in
            DispatchQueue.main.async { done(nil) }
        }
        if holdGate {
            root.appearancePaintGateForTesting = { [weak self] ready in
                self?.heldGateAnswers.append(ready)
            }
        } else {
            root.appearancePaintGateForTesting = { ready in
                DispatchQueue.main.async { ready() }
            }
        }
        root.appearanceTimingForTesting = WebPaintGate.Timing(
            snapshotBackstop: 0.25, paintBackstop: 0.6, fade: 0.01)
    }

    // MARK: - The cover must not eat the editor's touches

    func testTheCoverDoesNotSwallowTapsWhileItIsUp() {
        // The cover is an opaque view over the editor's whole rect, and it
        // stays up until the page reports a paint or `paintBackstop` (0.6s)
        // expires. A plain NSView takes touches, so for that whole window a
        // tap into the editor would land on the shield and do nothing --
        // costing no CPU at all and reading exactly like a sluggish app.
        // The cover masks PIXELS; it was never meant to gate input.
        injectSeams(holdGate: true)
        Preferences.themePreference = .dark
        root.applyThemePreference()
        pump(upTo: 2.0) { root.appearanceTransitionTrailForTesting.contains("cover-installed") }

        guard let editorView = root.editorForTesting.viewIfLoaded else {
            return XCTFail("the editor column must be loaded to host a cover")
        }
        XCTAssertTrue(root.isAppearanceCoverActiveForTesting,
                      "precondition: the cover is up for this assertion to mean anything")
        let mid = CGPoint(x: editorView.bounds.midX, y: editorView.bounds.midY)
        let hit = editorView.hitTest(editorView.superview!.convert(mid, from: editorView))
        let covers = editorView.subviews.filter { $0 is PassthroughView && $0.frame.contains(mid) }
        XCTAssertFalse(covers.isEmpty, "precondition: a cover must sit over the tap point")
        XCTAssertFalse(
            covers.contains(where: { cover in hit.map { $0 === cover || $0.isDescendant(of: cover) } ?? false }),
            "a tap mid-transition must reach the editor, not the transition cover")
    }

    // MARK: - The preference route

    func testPreferenceFlipCoversBeforeTheTraitFlipAndPushesInTheSameTurn() {
        injectSeams(holdGate: true)
        Preferences.themePreference = .dark
        root.applyThemePreference()

        pump(upTo: 2.0) { root.appearanceTransitionTrailForTesting.contains("style-applied") }
        let trail = root.appearanceTransitionTrailForTesting
        guard let cover = trail.firstIndex(of: "cover-installed"),
              let flip = trail.firstIndex(of: "style-applied"),
              let push = trail.firstIndex(of: "appearance-pushed") else {
            return XCTFail("the covered transition must install, flip and push; trail=\(trail)")
        }
        XCTAssertLessThan(cover, flip, "the cover is installed BEFORE the trait flips; trail=\(trail)")
        // finish() runs makeCover and the flip turn synchronously: the push
        // lands in the same turn as the flip, and the pump above could only
        // observe them together.
        XCTAssertEqual(push, flip + 1, "the data-theme push rides the same turn as the flip; trail=\(trail)")
        XCTAssertEqual(root.view.appearance?.name, .darkAqua)
        XCTAssertTrue(root.isAppearanceCoverActiveForTesting,
                      "the cover outlives the flip until the page has painted")

        heldGateAnswers.first?()
        pump(upTo: 2.0) { !root.isAppearanceCoverActiveForTesting }
        XCTAssertFalse(root.isAppearanceCoverActiveForTesting,
                       "the cover leaves after the paint gate answers")
    }

    func testUnchangedPreferenceInstallsNoCover() {
        injectSeams()
        Preferences.themePreference = .dark
        root.applyThemePreference()
        pump(upTo: 1.0) { !root.isAppearanceCoverActiveForTesting
            && root.appearanceTransitionTrailForTesting.contains("appearance-pushed") }
        let count = root.appearanceTransitionTrailForTesting.count
        // Re-applying the SAME preference (the Settings broadcast fires on
        // every general change) must not flash a cover.
        root.applyThemePreference()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(root.appearanceTransitionTrailForTesting.count, count,
                       "an unchanged preference is not a transition")
        XCTAssertFalse(root.isAppearanceCoverActiveForTesting)
    }

    // MARK: - A colour theme change

    /// Same light/dark, new theme: still a covered transition, and the root's trait carries the
    /// theme by the time the page is told.
    func testAThemeOnlyChangeIsACoveredTransition() {
        injectSeams()
        root.appearanceTransitionTrailForTesting.removeAll()
        Preferences.colorTheme = .catppuccin
        root.applyThemePreference()

        pump(upTo: 2.0) { root.appearanceTransitionTrailForTesting.contains("appearance-pushed") }
        let trail = root.appearanceTransitionTrailForTesting
        XCTAssertEqual(ChalkAppearance.theme, .catppuccin)
        guard let cover = trail.firstIndex(of: "cover-installed"),
              let push = trail.firstIndex(of: "appearance-pushed") else {
            return XCTFail("a theme change must cover and push; trail=\(trail)")
        }
        XCTAssertLessThan(cover, push, "the page flips only under the cover; trail=\(trail)")
    }

    // MARK: - The system route (Auto)

    func testSystemFlipAlsoCoversAndPushesUnderTheCover() {
        injectSeams()
        Preferences.themePreference = .auto
        root.applyThemePreference() // override stays .unspecified: Auto follows the system
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        root.appearanceTransitionTrailForTesting.removeAll()

        // Stand-in for the OS flipping the system appearance: the hosting
        // window's override changes the root's trait without the root's own
        // override moving — exactly the Auto lane's shape.
        let flipped: NSAppearance.Name =
            root.view.effectiveAppearance.isChalkDark ? .aqua : .darkAqua
        window.appearance = NSAppearance(named: flipped)
        window.layoutIfNeeded()

        pump(upTo: 2.0) { root.appearanceTransitionTrailForTesting.contains("appearance-pushed") }
        let trail = root.appearanceTransitionTrailForTesting
        XCTAssertTrue(trail.contains("cover-installed"),
                      "the system route still covers the repaint; trail=\(trail)")
        XCTAssertFalse(trail.contains("style-applied"),
                       "the system route flips no override; trail=\(trail)")
        guard let cover = trail.firstIndex(of: "cover-installed"),
              let push = trail.firstIndex(of: "appearance-pushed") else { return }
        XCTAssertLessThan(cover, push, "the page flips only under the cover; trail=\(trail)")
        pump(upTo: 2.0) { !root.isAppearanceCoverActiveForTesting }
        XCTAssertFalse(root.isAppearanceCoverActiveForTesting)
        XCTAssertNil(root.view.appearance, "Auto keeps following the system")
    }

    // MARK: - Reduce Motion (via the same instant branch)

    func testInstantPolicyKeepsTheCover() {
        root.motionPolicyForTesting = .instant
        injectSeams(holdGate: true)
        Preferences.themePreference = .dark
        root.applyThemePreference()
        pump(upTo: 2.0) { root.appearanceTransitionTrailForTesting.contains("style-applied") }
        XCTAssertTrue(root.appearanceTransitionTrailForTesting.contains("cover-installed"),
                      "Reduce Motion swaps fades for zero durations but KEEPS the cover — "
                      + "the mismatch flash is correctness, not motion")
        XCTAssertTrue(root.isAppearanceCoverActiveForTesting)
        heldGateAnswers.first?()
        pump(upTo: 2.0) { !root.isAppearanceCoverActiveForTesting }
        XCTAssertFalse(root.isAppearanceCoverActiveForTesting)
    }

    // MARK: - The backstop and the rapid re-toggle

    func testDeadPaintGateReleasesTheCoverOnTheBackstop() {
        root.appearanceSnapshotterForTesting = { done in
            DispatchQueue.main.async { done(nil) }
        }
        root.appearancePaintGateForTesting = { _ in } // never answers
        root.appearanceTimingForTesting = WebPaintGate.Timing(
            snapshotBackstop: 0.25, paintBackstop: 0.2, fade: 0.01)
        Preferences.themePreference = .dark
        root.applyThemePreference()
        pump(upTo: 2.0) { root.appearanceTransitionTrailForTesting.contains("style-applied") }
        pump(upTo: 2.0) { !root.isAppearanceCoverActiveForTesting }
        XCTAssertFalse(root.isAppearanceCoverActiveForTesting,
                       "a stalled web process must not hold the cover past the backstop")
    }

    func testRapidThemeToggleCancelsThePreviousCover() {
        injectSeams(holdGate: true)
        Preferences.themePreference = .dark
        root.applyThemePreference()
        pump(upTo: 2.0) { root.appearanceTransitionTrailForTesting.contains("style-applied") }
        XCTAssertTrue(root.isAppearanceCoverActiveForTesting)

        // Toggle back before the first transition's gate answers: the stale
        // cover must be canceled, the new transition owns the surface.
        Preferences.themePreference = .light
        root.applyThemePreference()
        pump(upTo: 2.0) {
            root.appearanceTransitionTrailForTesting.filter { $0 == "style-applied" }.count == 2
        }
        XCTAssertEqual(root.view.appearance?.name, .aqua)
        XCTAssertEqual(heldGateAnswers.count, 2, "each transition asks its own gate")
        heldGateAnswers.first?() // the FIRST gate answering late must do nothing
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertTrue(root.isAppearanceCoverActiveForTesting,
                      "the stale gate must not release the NEW transition's cover")
        XCTAssertEqual(root.appearanceTransitionTrailForTesting.filter { $0 == "cover-installed" }.count, 2)
    }
}
