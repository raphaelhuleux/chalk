import XCTest
@testable import Chalk

/// The shell's half of auto-hiding chrome: the preference that governs it,
/// the scroll consumer that drives it, and the live re-apply that must reveal
/// the tabs the moment a reader turns the feature off. The decision table
/// itself is ChalkKit's (ChromeAutoHideGateTests).
@MainActor
final class ChromeAutoHideTests: XCTestCase {
    private let key = "chalk.autoHideChrome"

    private func withPreference(_ value: Bool, _ body: () -> Void) {
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        Preferences.autoHideChrome = value
        body()
    }

    /// A fresh install auto-hides: the feature is the design, the switch is
    /// the escape hatch.
    func testPreferenceDefaultsToOn() {
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(Preferences.autoHideChrome)
    }

    private func loadedRoot() -> RootSplitViewController {
        let root = RootSplitViewController()
        root.loadViewIfNeeded()
        root.view.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        root.view.layoutIfNeeded()
        return root
    }

    func testSustainedDownwardScrollHidesChrome() {
        withPreference(true) {
            let root = loadedRoot()
            XCTAssertFalse(root.isChromeAutoHiddenForTesting)
            for offset in stride(from: 100.0, through: 140.0, by: 10.0) {
                root.editorDidScroll(offset: offset)
            }
            XCTAssertTrue(root.isChromeAutoHiddenForTesting,
                          "40pt of downward travel crosses the hide threshold")
        }
    }

    func testScrollingBackUpRevealsChrome() {
        withPreference(true) {
            let root = loadedRoot()
            for offset in stride(from: 100.0, through: 140.0, by: 10.0) {
                root.editorDidScroll(offset: offset)
            }
            XCTAssertTrue(root.isChromeAutoHiddenForTesting)
            root.editorDidScroll(offset: 125)
            XCTAssertFalse(root.isChromeAutoHiddenForTesting,
                           "15pt back up clears the eager show threshold")
        }
    }

    func testPreferenceOffKeepsChromePinned() {
        withPreference(false) {
            let root = loadedRoot()
            for offset in stride(from: 100.0, through: 300.0, by: 10.0) {
                root.editorDidScroll(offset: offset)
            }
            XCTAssertFalse(root.isChromeAutoHiddenForTesting,
                           "with the switch off no amount of scrolling hides the tabs")
        }
    }

    private func item(_ id: UUID, name: String, dirty: Bool = false,
                      active: Bool = true) -> TabItem {
        TabItem(id: id, name: name, isDirty: dirty, isActive: active, isPreview: false)
    }

    /// A tab that arrives while the chrome is away would otherwise open into
    /// an invisible strip — the reader opens a file and sees no tab for it.
    func testOpeningATabRevealsHiddenChrome() {
        withPreference(true) {
            let root = loadedRoot()
            let first = UUID()
            root.handleTabsChanged([item(first, name: "a.md")])
            for offset in stride(from: 100.0, through: 140.0, by: 10.0) {
                root.editorDidScroll(offset: offset)
            }
            XCTAssertTrue(root.isChromeAutoHiddenForTesting)

            root.handleTabsChanged([
                item(first, name: "a.md", active: false),
                item(UUID(), name: "b.md"),
            ])
            XCTAssertFalse(root.isChromeAutoHiddenForTesting)
        }
    }

    /// The same update arrives on every dirty-flag flip. Typing must not make
    /// the chrome pop back — that is the exact flapping auto-hide exists to
    /// avoid.
    func testTypingInTheActiveTabLeavesChromeHidden() {
        withPreference(true) {
            let root = loadedRoot()
            let id = UUID()
            root.handleTabsChanged([item(id, name: "a.md")])
            for offset in stride(from: 100.0, through: 140.0, by: 10.0) {
                root.editorDidScroll(offset: offset)
            }
            XCTAssertTrue(root.isChromeAutoHiddenForTesting)

            root.handleTabsChanged([item(id, name: "a.md", dirty: true)])
            XCTAssertTrue(root.isChromeAutoHiddenForTesting,
                          "a dirty-marker update is not a tab the reader opened")
        }
    }

    /// Settings lives in its own scene: flipping the switch must reach every
    /// open window, and a window whose chrome is currently hidden must get it
    /// back rather than wait for the reader to scroll up.
    func testTurningPreferenceOffRevealsHiddenChromeLive() {
        withPreference(true) {
            let root = loadedRoot()
            for offset in stride(from: 100.0, through: 140.0, by: 10.0) {
                root.editorDidScroll(offset: offset)
            }
            XCTAssertTrue(root.isChromeAutoHiddenForTesting)

            Preferences.autoHideChrome = false
            NotificationCenter.default.post(
                name: Preferences.autoHideChromeDidChange, object: nil)
            XCTAssertFalse(root.isChromeAutoHiddenForTesting)
        }
    }
}
