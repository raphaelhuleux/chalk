import XCTest
@testable import Chalk
import ChalkKit

/// The banner asks the tester for something. Everything about it is shaped by
/// one risk: an ask that is easy to ignore, hard to refuse, or in the way of
/// typing trains the tester to dismiss it reflexively, and then the real report
/// never arrives.
final class NoticeBannerTests: XCTestCase {
    private func banner(onPrimary: @escaping () -> Void = {},
                        onDecline: @escaping () -> Void = {}) -> NoticeBannerView {
        NoticeBannerView(
            message: "Chalk didn\u{2019}t shut down cleanly last time.",
            primaryTitle: "Send a report",
            declineTitle: "No thanks",
            onPrimary: onPrimary,
            onDecline: onDecline)
    }

    /// The editor is the app. A banner that can take the keyboard steals a
    /// keystroke from someone mid-sentence, which is a worse bug than the one
    /// it is asking about.
    func testTheBannerNeverTakesFirstResponder() {
        let view = banner()
        XCTAssertFalse(view.canBecomeFirstResponder)
        XCTAssertFalse(view.becomeFirstResponder())
        for control in view.buttonsForTesting {
            XCTAssertFalse(control.canBecomeFirstResponder,
                           "'\(control.title(for: .normal) ?? "")' can take focus")
        }
    }

    /// Only the banner's own controls swallow touches. Anywhere else, the tap
    /// reaches the editor underneath.
    func testTapsOutsideTheControlsFallThroughToTheEditor() {
        let view = banner()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 60)
        view.layoutIfNeeded()
        XCTAssertNil(view.hitTest(CGPoint(x: 5, y: 30), with: nil),
                     "the banner's empty space must not absorb a tap")
    }

    /// Equal visual weight, so refusing is as easy as accepting. A greyed-out
    /// "No thanks" beside a filled "Send a report" is a dark pattern, and a
    /// tester who feels handled stops helping.
    func testAcceptingAndRefusingLookTheSame() {
        let buttons = banner().buttonsForTesting.filter { $0.title(for: .normal) != nil }
        XCTAssertEqual(buttons.count, 2)
        XCTAssertEqual(buttons[0].titleLabel?.font, buttons[1].titleLabel?.font)
        XCTAssertEqual(buttons[0].isEnabled, buttons[1].isEnabled)
    }

    /// No "Not now". A third option that defers is how a prompt becomes
    /// permanent: it never counts as a refusal, so it can be asked forever.
    func testThereIsNoDeferOption() {
        let titles = banner().buttonsForTesting.compactMap { $0.title(for: .normal) }
        XCTAssertEqual(Set(titles), ["Send a report", "No thanks"])
        for title in titles {
            XCTAssertFalse(title.lowercased().contains("later"))
            XCTAssertFalse(title.lowercased().contains("not now"))
        }
    }

    func testPressingSendRunsThePrimaryActionOnce() {
        var sent = 0
        let view = banner(onPrimary: { sent += 1 })
        view.pressPrimaryForTesting()
        XCTAssertEqual(sent, 1)
    }

    func testPressingNoThanksRecordsARefusal() {
        var declined = 0
        let view = banner(onDecline: { declined += 1 })
        view.pressDeclineForTesting()
        XCTAssertEqual(declined, 1)
    }

    /// Walking away is an answer. If a banner that times out costs nothing, the
    /// app can ask forever by making the ask easy to ignore.
    func testTimingOutCountsAsARefusal() {
        var declined = 0
        let view = banner(onDecline: { declined += 1 })
        view.dismissForTesting()
        XCTAssertEqual(declined, 1)
    }

    /// Whichever way it goes away, it goes away once. A banner that reports two
    /// refusals for one dismissal burns through the three-strike budget in a
    /// single crash.
    func testAnAnsweredBannerCannotAnswerAgain() {
        var declined = 0
        var sent = 0
        let view = banner(onPrimary: { sent += 1 }, onDecline: { declined += 1 })

        view.pressPrimaryForTesting()
        view.dismissForTesting()
        view.pressDeclineForTesting()

        XCTAssertEqual(sent, 1)
        XCTAssertEqual(declined, 0, "dismissal after an answer must not also count")
    }

    // MARK: - who gets asked at all

    /// A session that crashed last time, so the crash prompt is due.
    private func crashedSession() -> AlphaSession {
        let defaults = UserDefaults(suiteName: "chalk-notice-tests-\(UUID().uuidString)")!
        let build = BuildInfo(infoDictionary: ["CFBundleVersion": "42"])
        // First session goes to the foreground and never marks a clean exit:
        // the next one reads that as an abnormal end.
        AlphaSession(build: build, defaults: defaults).markForeground()
        return AlphaSession(build: build, defaults: defaults)
    }

    private func presentedBanner(in root: RootSplitViewController) -> NoticeBannerView? {
        root.view.subviews.compactMap { $0 as? NoticeBannerView }.first
    }

    /// An app that shut down badly should say so and offer to report it.
    func testACrashedLaunchShowsTheCrashPrompt() {
        let alpha = crashedSession()
        XCTAssertTrue(alpha.shouldPromptAboutCrash,
                      "precondition: the prompt is due on its own terms")

        let root = RootSplitViewController(initialContent: .openEmpty)
        root.alphaSessionForTesting = alpha
        root.loadViewIfNeeded()
        root.presentAlphaNoticeIfNeeded()

        XCTAssertNotNil(presentedBanner(in: root),
                        "reporting a bad shutdown is an ordinary feature")
    }
}
