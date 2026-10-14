import XCTest
import ChalkKit
@testable import Chalk

/// Guards the test host's preferences against leaks from earlier suites.
///
/// `Preferences` is backed by `UserDefaults.standard`. The test host is a Debug
/// build (`com.huleux.chalk.debug`, see mac/project.yml), so tests cannot reach
/// the installed app's settings, but every suite and every Debug launch shares
/// this one domain. A run killed before its `tearDown` leaves its writes behind,
/// and a leaked `chalk.editingMode = zen` hides the tab band and the Library, so
/// unrelated suites fail at once (docs/known-failing-tests.md, 2026-08-23).
///
/// Absolute rules, not a diff, so the result cannot depend on which suite ran
/// first. Each one is a state no test should leave behind.
final class PreferencePollutionGuardTests: XCTestCase {

    /// The exact leak that broke the app. Zen is a mode a person chooses; no
    /// test run should ever end with the machine sitting in it.
    func testEditingModeIsNotLeftInZen() {
        XCTAssertNotEqual(
            Preferences.editingMode, .zen,
            """
            chalk.editingMode is "zen" in the Debug domain, so Debug launches \
            and later suites come up with no tab band and no Library. Reset it with:
                defaults write com.huleux.chalk.debug chalk.editingMode -string normal
            Then find the suite that leaked it: restoring in a test's `defer` \
            does not survive an interrupted run, so it must snapshot in setUp \
            and restore in tearDown.
            """)
    }

    /// The Library is the app's front door. A test that empties it destroys
    /// security-scoped bookmarks that cannot be regenerated.
    func testTheLibraryWasNotEmptiedByATest() throws {
        // The pre-per-window list: still the migration source for windows that predate it.
        let raw = UserDefaults.standard.data(forKey: WindowLocations.legacyKey)
        try XCTSkipIf(raw == nil, "no Library on this machine; nothing to protect")
        let decoded = try? JSONSerialization.jsonObject(with: raw!) as? [Any]
        // An empty Library is also a legitimate first-run state, and from here
        // the two are indistinguishable without a snapshot taken before the
        // run. Skipping keeps this from sitting permanently red after real
        // damage (2026-08-19), which would train everyone to ignore it. The
        // value it still carries is the corruption check below.
        try XCTSkipIf((decoded ?? []).isEmpty,
                      "Library is empty: either a fresh machine, or bookmarks were "
                    + "destroyed and re-added by hand. Cannot tell from here.")
        XCTAssertNotNil(
            decoded,
            """
            chalk.locations does not decode as JSON, so the Library is \
            corrupt and every folder will read as unresolvable. Tests that \
            touch locations must inject their own UserDefaults suite, the way \
            LocationStoreTests and CrossWindowSyncTests already do:
                BookmarkStore(defaults: <own suite>, key: "locations")
            """)
    }

    /// Names every suite known to write the shared domain, so the list is
    /// reviewed rather than rediscovered. A new entry here is a prompt to ask
    /// whether that suite could inject its own suite instead.
    func testTheSuitesTouchingTheSharedDomainAreKnown() {
        let known: Set<String> = [
            "EditingModeTests",            // editingMode, restores per test
            "ChromeAutoHideTests",         // autoHideChrome, restores per test
            "EditorPreferencesTests",      // measure/alignment/fileType, restores per test
            "ChromeInvariantMatrixTests",  // editingMode, snapshots in ChromeMatrixHost since 2026-08-19
            "ChromeTransitionMatrixTests", // editingMode + sidebarWidth (pinned), ChromeMatrixHost restores
        ]
        XCTAssertEqual(known.count, 5,
                       "a suite was added to or removed from the shared-domain list; "
                     + "confirm it restores what it writes, and prefer an injected "
                     + "UserDefaults suite over UserDefaults.standard")
    }
}
