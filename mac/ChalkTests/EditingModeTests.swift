import XCTest
import ChalkKit
@testable import Chalk

/// Editing-mode logic that doesn't need pixels: the enum's cycle/wire mapping,
/// the preference fallback, and zen's chrome side effects on a live
/// RootSplitViewController (header hidden, safe-area inset reclaimed, and both
/// restored on exit). App-hosted.
@MainActor
final class EditingModeTests: XCTestCase {
    func testCycleOrderAndWireValues() {
        XCTAssertEqual(EditingMode.normal.next, .zen)
        XCTAssertEqual(EditingMode.zen.next, .typewriter)
        XCTAssertEqual(EditingMode.typewriter.next, .focus)
        XCTAssertEqual(EditingMode.focus.next, .normal)
        // The wire value rides in Preferences.editorConfigPayload (ViewModeTests).
        XCTAssertEqual(EditingMode.typewriter.rawValue, "typewriter")
    }

    func testPreferenceFallsBackToNormalOnUnknownRawValue() {
        let previous = UserDefaults.standard.string(forKey: "chalk.editingMode")
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: "chalk.editingMode")
            } else {
                UserDefaults.standard.removeObject(forKey: "chalk.editingMode")
            }
        }
        UserDefaults.standard.set("bogus-future-mode", forKey: "chalk.editingMode")
        XCTAssertEqual(Preferences.editingMode, .normal)
        Preferences.editingMode = .focus
        XCTAssertEqual(Preferences.editingMode, .focus)
    }

    /// C3 (docs/motion.md): the zen band change FADES over `motionStandard`
    /// on the animated lane, and `isHidden` — the asserted final state —
    /// lands in the fade's completion. This test drives the REAL lane, so it
    /// waits the clock out; on Reduce Motion machines the wait is just slack.
    private func pumpZenFade() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: ChalkMetrics.motionStandard + 0.15))
    }

    /// Zen hides the tab band; it must not touch
    /// `additionalSafeAreaInsets`. The band is an OVERLAY (option 2a: the
    /// editor runs full-bleed under it and gets its resting offset web-side,
    /// the `editorChromeTopInset` `BandLayout.resolve` returns to
    /// `applyBandLayout()`), so reserving header height on zen EXIT
    /// pushed both columns down by 44 and, because the band's own pad reads
    /// `view.safeAreaInsets.top`, inflated the band itself by the same amount
    /// — a zen round trip left a fat black bar over the tabs (owner report
    /// 2026-08-18). Launch leaves the inset at 0; leaving zen must return to
    /// exactly that. Replaces the old expectation of `headerHeight`, which was
    /// the pre-overlay model and had become a known-failing baseline entry.
    /// The windowed tabs live in the AppKit NSToolbar and the UIKit band is
    /// hidden at rest, showing only as the fallback when the glue fails to
    /// load, so the band's resting visibility is not asserted here.
    ///
    /// The whole point of the test: the inset must be 0 throughout, and the
    /// band must come back the size it launched.
    @MainActor
    func testZenHidesTheHeaderWithoutMovingTheColumns() {
        let previousMode = Preferences.editingMode
        defer { Preferences.editingMode = previousMode }

        // Hosted in a real window, not just loaded.
        //
        // An unhosted root has no safe area, and the band's height is
        // `max(view.safeAreaInsets.top, tabStripHeight)`. With the inset at 0
        // the floor always binds, so "the height at launch" was really the
        // unlaid seed constant (s(44)) and the first presentation pass raised
        // it to the s(46) floor. The test read that correction as a zen
        // regression. docs/ui-correctness.md lists unhosted roots as the first
        // way this class of test goes quietly wrong; this is one.
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        let root = RootSplitViewController()
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
        root.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        // The band's resting visibility is the toolbar's business; this
        // test is about the inset and the round trip, not about ownership.
        let restingHidden = root.isHeaderHiddenForTesting
        XCTAssertEqual(root.additionalSafeAreaInsets.top, 0)
        let band = root.headerBandHeightForTesting

        root.setEditingMode(.zen)
        pumpZenFade()
        XCTAssertTrue(root.isHeaderHiddenForTesting,
                      "zen hides the band")
        XCTAssertEqual(root.additionalSafeAreaInsets.top, 0)
        XCTAssertEqual(Preferences.editingMode, .zen)

        root.setEditingMode(.normal)
        pumpZenFade()
        root.view.layoutIfNeeded()
        XCTAssertEqual(root.isHeaderHiddenForTesting, restingHidden,
                       "leaving zen returns the band to the visibility it launched with")
        XCTAssertEqual(root.additionalSafeAreaInsets.top, 0)
        XCTAssertEqual(root.headerBandHeightForTesting, band, accuracy: 0.5,
                       "a zen round trip returns the band to its launch height")
    }

    /// The pill's editing-mode menu is a per-WINDOW control, so it must read
    /// the window it lives in.
    ///
    /// It used to read `Preferences.editingMode` — the global, last-writer-wins
    /// value — so entering zen in one window put the checkmark on "Zen" in
    /// every other window's pill while those windows stayed in normal mode.
    /// Both roots are window-hosted for the same reason the zen test above is:
    /// `setEditingMode` runs the real chrome transition, which wants a real
    /// safe area.
    @MainActor
    func testThePillReportsItsOwnWindowsEditingMode() {
        let previousMode = Preferences.editingMode
        defer { Preferences.editingMode = previousMode }
        Preferences.editingMode = .normal

        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first!

        func host(_ root: RootSplitViewController) -> UIWindow {
            let window = UIWindow(windowScene: scene)
            window.rootViewController = root
            window.isHidden = false
            window.layoutIfNeeded()
            root.view.layoutIfNeeded()
            return window
        }

        let zenRoot = RootSplitViewController(initialContent: .openEmpty)
        let normalRoot = RootSplitViewController(initialContent: .openEmpty)
        let zenWindow = host(zenRoot)
        let normalWindow = host(normalRoot)
        defer {
            for window in [zenWindow, normalWindow] {
                window.isHidden = true
                window.rootViewController = nil
            }
        }

        XCTAssertEqual(zenRoot.pillEditingModeForTesting, .normal)
        XCTAssertEqual(normalRoot.pillEditingModeForTesting, .normal)

        // The same path the View menu and the pill's own menu take.
        zenRoot.setEditingMode(.zen)
        pumpZenFade()

        XCTAssertEqual(zenRoot.pillEditingModeForTesting, .zen,
                       "the window that entered zen checkmarks zen")
        XCTAssertEqual(normalRoot.pillEditingModeForTesting, .normal,
                       "a second window keeps reporting its OWN mode after "
                       + "another window enters zen")
    }
}
