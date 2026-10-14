import XCTest
@testable import ChalkKit

/// When the app is allowed to ask about a crash.
///
/// Pulled out of the view controllers on purpose. Escalation rules scattered
/// across a banner, a scene delegate and a settings screen are the shape that
/// produces a prompt nobody can turn off, and this one has to be turnable off:
/// the tester agreed to try an editor, not to be interviewed by it.
final class CrashPromptPolicyTests: XCTestCase {
    func testAnOrderlyPreviousSessionIsNeverWorthAsking() {
        for verdict in [LaunchVerdict.clean, .firstLaunch] {
            XCTAssertFalse(CrashPromptPolicy.shouldPrompt(
                verdict: verdict, declines: 0, userOptedOut: false),
                "\(verdict) is not a crash")
        }
    }

    func testACrashWithNoHistoryPrompts() {
        XCTAssertTrue(CrashPromptPolicy.shouldPrompt(
            verdict: .abnormal(build: "42"), declines: 0, userOptedOut: false))
    }

    /// The escalation ceiling. Three refusals is an answer.
    func testThreeDeclinesStopTheAskingForGood() {
        XCTAssertTrue(CrashPromptPolicy.shouldPrompt(
            verdict: .abnormal(build: "42"), declines: 2, userOptedOut: false),
            "the third ask is still allowed")
        XCTAssertFalse(CrashPromptPolicy.shouldPrompt(
            verdict: .abnormal(build: "42"), declines: 3, userOptedOut: false),
            "the fourth is not")
        XCTAssertFalse(CrashPromptPolicy.shouldPrompt(
            verdict: .abnormal(build: "42"), declines: 99, userOptedOut: false))
    }

    /// The Settings toggle. The app never re-enables it, so no verdict and no
    /// counter may override it.
    func testAnExplicitOptOutBeatsEverything() {
        XCTAssertFalse(CrashPromptPolicy.shouldPrompt(
            verdict: .abnormal(build: "42"), declines: 0, userOptedOut: true))
    }

    func testDecliningCountsUp() {
        XCTAssertEqual(CrashPromptPolicy.declines(after: .declined, from: 0), 1)
        XCTAssertEqual(CrashPromptPolicy.declines(after: .declined, from: 1), 2)
    }

    /// Someone who sends a report has not opted out of anything. Letting the
    /// count survive would silently retire the prompt for the tester who is
    /// actually helping.
    func testSendingAReportClearsTheHistory() {
        XCTAssertEqual(CrashPromptPolicy.declines(after: .sent, from: 2), 0)
        XCTAssertEqual(CrashPromptPolicy.declines(after: .sent, from: 0), 0)
    }

    /// A stored counter can be anything: a corrupted preference, an older
    /// build's key, a hand edit. None of those may make the prompt reappear.
    func testAnAbsurdStoredCountIsClampedNotWrappedAround() {
        XCTAssertEqual(CrashPromptPolicy.declines(after: .declined, from: 9_999),
                       CrashPromptPolicy.declineLimit)
        XCTAssertEqual(CrashPromptPolicy.declines(after: .declined, from: -5), 1)
        XCTAssertFalse(CrashPromptPolicy.shouldPrompt(
            verdict: .abnormal(build: "42"), declines: Int.max, userOptedOut: false))
    }

    /// A negative count must not read as "never asked yet" in the direction
    /// that suppresses the prompt.
    func testANegativeStoredCountStillAllowsTheFirstAsk() {
        XCTAssertTrue(CrashPromptPolicy.shouldPrompt(
            verdict: .abnormal(build: "42"), declines: -1, userOptedOut: false))
    }
}
