import XCTest
@testable import ChalkMac
import ChalkKit

/// The state for one run of the app: how the last session ended, and whether
/// the user still wants to be asked about crashes.
///
/// Built against an injected defaults suite so no test can leave a marker or a
/// decline count in the real preferences. A suite that leaked here would make
/// the next run of the whole suite disagree with itself, which is the failure
/// mode ChromeInvariantMatrixTests already has to work around.
final class AlphaSessionTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "chalk-alpha-tests-\(UUID().uuidString)")
    }

    private func session() -> AlphaSession {
        AlphaSession(build: BuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "42",
            "CHALKGitCommit": "deadbee",
        ]), defaults: defaults)
    }

    // MARK: - crash verdict

    func testTheFirstRunIsNotACrash() {
        XCTAssertEqual(session().verdict, .firstLaunch)
        XCTAssertFalse(session().shouldPromptAboutCrash)
    }

    func testACrashIsSurfacedOnce() {
        let crashed = session()
        crashed.markForeground()
        // Died here.

        let next = session()
        XCTAssertEqual(next.verdict, .abnormal(build: "42"))
        XCTAssertTrue(next.shouldPromptAboutCrash)
    }

    func testAnOrderlyExitPromptsNobody() {
        let clean = session()
        clean.markForeground()
        clean.markClean()

        XCTAssertFalse(session().shouldPromptAboutCrash)
    }

    // MARK: - the escalation ceiling

    func testThreeDeclinesRetireThePromptPermanently() {
        for expected in [true, true, true, false] {
            let run = session()
            run.markForeground()
            let next = session()
            XCTAssertEqual(next.shouldPromptAboutCrash, expected)
            next.recordCrashPromptOutcome(.declined)
        }
    }

    func testSendingAReportKeepsThePromptAlive() {
        for _ in 0..<2 {
            let run = session()
            run.markForeground()
            session().recordCrashPromptOutcome(.declined)
        }
        let run = session()
        run.markForeground()
        session().recordCrashPromptOutcome(.sent)

        let afterSending = session()
        afterSending.markForeground()
        XCTAssertTrue(session().shouldPromptAboutCrash,
                      "a user who sends a report has not opted out of anything")
    }

    /// The Settings toggle. Nothing the app does may turn it back on.
    func testTheOptOutSurvivesACrashAndAClearedCount() {
        let opted = session()
        opted.isCrashPromptEnabled = false
        opted.recordCrashPromptOutcome(.sent)   // would otherwise clear the count

        let crashed = session()
        crashed.markForeground()
        XCTAssertFalse(session().shouldPromptAboutCrash)
    }

    // MARK: - one banner, one window

    /// Several windows all activate at launch and all ask. The crash happened
    /// once, so it is reported once: four banners for one fact is how a user
    /// learns that Chalk nags.
    func testOnlyTheFirstWindowToAskGetsToShowTheCrashPrompt() {
        let crashed = session()
        crashed.markForeground()

        let launch = session()
        XCTAssertTrue(launch.claimCrashPrompt(), "the first window asks")
        XCTAssertFalse(launch.claimCrashPrompt(), "the second window does not")
        XCTAssertFalse(launch.claimCrashPrompt())
    }

    func testAWindowCannotClaimAPromptThatIsNotWarranted() {
        let clean = session()
        clean.markForeground()
        clean.markClean()

        XCTAssertFalse(session().claimCrashPrompt(),
                       "no crash, no prompt, however many windows ask")
    }

    /// Claiming must not consume the budget: the count moves when the user
    /// answers, not when a window renders.
    func testClaimingDoesNotCountAsARefusal() {
        let crashed = session()
        crashed.markForeground()

        let launch = session()
        _ = launch.claimCrashPrompt()
        XCTAssertEqual(defaults.integer(forKey: "chalk.crashPromptDeclines"), 0)
    }
}
