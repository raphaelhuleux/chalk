import XCTest
import ChalkKit
@testable import ChalkMac

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

    /// Zen hides the tab band and a round trip must return it at the size it
    /// launched: the band is an OVERLAY (the editor runs full-bleed under it
    /// and gets its resting offset web-side), so nothing may reserve header
    /// height on zen exit and push the columns down.
    @MainActor
    func testZenHidesTheHeaderWithoutMovingTheColumns() {
        let previousMode = Preferences.editingMode
        defer { Preferences.editingMode = previousMode }

        // Hosted in a real window, not just loaded: an unhosted root has no
        // titlebar to measure, so the band's height there is only the floor.
        // docs/ui-correctness.md lists unhosted roots as the first way this
        // class of test goes quietly wrong.
        
        let window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let root = RootSplitViewController()
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
        root.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let restingHidden = root.isHeaderHiddenForTesting
        let band = root.headerBandHeightForTesting

        root.setEditingMode(.zen)
        pumpZenFade()
        XCTAssertTrue(root.isHeaderHiddenForTesting,
                      "zen hides the band")
        XCTAssertEqual(Preferences.editingMode, .zen)

        root.setEditingMode(.normal)
        pumpZenFade()
        root.view.layoutIfNeeded()
        XCTAssertEqual(root.isHeaderHiddenForTesting, restingHidden,
                       "leaving zen returns the band to the visibility it launched with")
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

        

        func host(_ root: RootSplitViewController) -> NSWindow {
            let window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
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
