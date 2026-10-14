import XCTest
@testable import ChalkKit

/// The only crash signal an alpha outside TestFlight will ever have.
///
/// The mechanism is one marker in UserDefaults holding the build string while a
/// foreground session is live. If the app is still holding it at the next
/// launch, nobody cleared it, which means nothing ran the clean-shutdown path,
/// which means the process died while the user was looking at it.
///
/// Each test drives the real lifecycle order rather than poking the store, so a
/// missed call site fails here rather than in the field.
final class LaunchIntegrityTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "chalk-launch-tests-\(UUID().uuidString)")
    }

    private func integrity(build: String = "42") -> LaunchIntegrity {
        LaunchIntegrity(defaults: defaults, build: build, key: "chalk.test.launch")
    }

    func testTheFirstEverLaunchIsNotACrash() {
        XCTAssertEqual(integrity().beginSession(), .firstLaunch)
    }

    func testBackgroundingThenRelaunchingIsClean() {
        let first = integrity()
        _ = first.beginSession()
        first.markForeground()
        first.markClean()

        XCTAssertEqual(integrity().beginSession(), .clean)
    }

    /// The whole point: nothing ran between `markForeground` and the next
    /// launch, so the marker is still armed.
    func testDyingWhileForegroundedIsReportedAsAbnormal() {
        let first = integrity(build: "117")
        _ = first.beginSession()
        first.markForeground()
        // No markClean: the process died here.

        XCTAssertEqual(integrity(build: "117").beginSession(), .abnormal(build: "117"))
    }

    /// A death in a build the user has since replaced is still worth knowing
    /// about, but it is not a report about the build they are running now. The
    /// marker holds the build string precisely so these are tellable apart.
    func testTheVerdictNamesTheBuildThatDiedNotTheOneRunningNow() {
        let old = integrity(build: "116")
        _ = old.beginSession()
        old.markForeground()

        XCTAssertEqual(integrity(build: "117").beginSession(), .abnormal(build: "116"))
    }

    /// Deliberate, and the cost of a fail-open design. A process the OS starts
    /// in the background and kills before the user ever sees it must not be
    /// reported as a crash: on a device that is ordinary memory management, and
    /// a prompt for it would be a lie the tester cannot check.
    func testDyingBeforeAnythingWasEverForegroundedIsNotACrash() {
        let first = integrity()
        _ = first.beginSession()
        // Launched, never foregrounded, killed.

        XCTAssertEqual(integrity().beginSession(), .clean)
    }

    /// Backgrounding and returning is the common case and must not arm the
    /// marker permanently or disarm it permanently.
    func testForegroundBackgroundCyclesTrackTheCurrentState() {
        let session = integrity()
        _ = session.beginSession()

        session.markForeground()
        session.markClean()
        session.markForeground()
        // Died while foregrounded, after two clean cycles.

        XCTAssertEqual(integrity().beginSession(), .abnormal(build: "42"))
    }

    /// A crash is reported once. The second launch after it must be clean, or
    /// the prompt reappears forever and the tester learns to dismiss it.
    func testACrashIsReportedOnceAndThenTheSlateIsClear() {
        let crashed = integrity()
        _ = crashed.beginSession()
        crashed.markForeground()

        XCTAssertEqual(integrity().beginSession(), .abnormal(build: "42"))
        XCTAssertEqual(integrity().beginSession(), .clean)
    }

    /// `beginSession` must not arm the marker itself. If it did, every launch
    /// that the user quit from the Dock before a scene foregrounded would
    /// report a crash.
    func testBeginSessionDoesNotArmTheMarkerOnItsOwn() {
        let session = integrity()
        _ = session.beginSession()

        XCTAssertEqual(integrity().beginSession(), .clean)
    }

    func testMarkingCleanTwiceIsHarmless() {
        let session = integrity()
        _ = session.beginSession()
        session.markForeground()
        session.markClean()
        session.markClean()

        XCTAssertEqual(integrity().beginSession(), .clean)
    }

    /// Two instances sharing one store must not read each other's marker as a
    /// crash. On Catalyst several windows are several scenes in one process,
    /// and each one calls the foreground and background hooks.
    func testSeveralScenesInOneProcessDoNotFakeACrash() {
        let session = integrity()
        _ = session.beginSession()

        session.markForeground()   // window A appears
        session.markForeground()   // window B appears
        session.markClean()        // window A goes away
        session.markClean()        // window B goes away, app is now background

        XCTAssertEqual(integrity().beginSession(), .clean)
    }
}
