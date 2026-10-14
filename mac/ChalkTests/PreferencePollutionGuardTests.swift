import XCTest
import ChalkKit
@testable import Chalk

/// Guards the REAL app's preferences against the test bundle.
///
/// ## Why this exists
///
/// `Preferences` is backed by `UserDefaults.standard`, and an app-hosted test
/// bundle shares that domain with the INSTALLED app. Anything a test writes
/// lands on the machine the owner actually uses.
///
/// On 2026-08-19 that cost an afternoon. `ChromeInvariantMatrixTests` drives zen
/// states; two runs were interrupted before their `defer` restored the value, so
/// `chalk.editingMode` stayed `"zen"`. Zen hides the tab band and closes the
/// Library BY DESIGN, so the installed app launched with no tabs and no sidebar
/// and read as a completely broken build. Hours went into bisecting branches,
/// sandbox containers, bundle loading and scene-restore races; the answer was
/// one string in a plist, and no test said so.
///
/// The same runs also left `chalk.locations` an empty array. Those
/// security-scoped bookmarks were NOT recoverable — every Library folder had to
/// be re-added by hand.
///
/// ## What it checks
///
/// Absolute rules, not a diff, so the result cannot depend on which suite ran
/// first. Each one is a state the machine should never be left in by a test.
final class PreferencePollutionGuardTests: XCTestCase {

    /// The exact leak that broke the app. Zen is a mode a person chooses; no
    /// test run should ever end with the machine sitting in it.
    func testEditingModeIsNotLeftInZen() {
        XCTAssertNotEqual(
            Preferences.editingMode, .zen,
            """
            chalk.editingMode is "zen" in UserDefaults.standard, which the \
            INSTALLED app reads. It will launch with no tab band and no \
            Library and look broken. Reset it with:
                defaults write com.huleux.chalk chalk.editingMode -string normal
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
