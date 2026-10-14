import XCTest
@testable import ChalkKit

/// The bytes a user is about to file, composed where they can be tested
/// rather than inside a view controller.
///
/// The app transmits nothing. This builds a draft issue; the user reads it and
/// submits it in their own browser. That only stays honest if what the in-app
/// preview shows is exactly what leaves, which is why composition is one pure
/// function with no side channel.
final class BugReportTests: XCTestCase {
    private let env = BugReportEnvironment(
        appVersion: "1.0.0", build: "42", commit: "deadbee",
        systemVersion: "macOS 15.6", model: "Mac", locale: "fr_FR")

    private let base = "https://example.com/issues/new"

    private func body(kind: BugReportKind = .bug,
                      notes: String = "It went wrong.",
                      diagnostics: String? = "12.3s scene-active a=2\n") -> String {
        BugReport.body(kind: kind, notes: notes, environment: env, diagnostics: diagnostics)
    }

    // MARK: - shape

    func testTheUsersOwnWordsComeFirst() {
        let text = body(notes: "The window came up empty.")
        XCTAssertTrue(text.hasPrefix("The window came up empty."),
                      "the user's report must open the issue, not the telemetry")
    }

    func testDiagnosticsAreLastAndFenced() {
        let text = body()
        let fenceStart = try? XCTUnwrap(text.range(of: BugReport.diagnosticsFence))
        XCTAssertNotNil(fenceStart)
        XCTAssertTrue(text.range(of: "scene-active")!.lowerBound
                      > text.range(of: BugReport.diagnosticsFence)!.lowerBound,
                      "the ring must sit behind the fence, not before it")
        XCTAssertTrue(text.range(of: BugReport.diagnosticsFence)!.lowerBound
                      > text.range(of: "1.0.0")!.lowerBound,
                      "environment before diagnostics: deleting the ring must not "
                      + "take the build identity with it")
    }

    /// The fence exists so declining to send diagnostics is one gesture. If the
    /// fence stays when the block is gone, the user is left staring at an
    /// empty section wondering what was removed.
    func testOmittingDiagnosticsRemovesTheFenceToo() {
        let text = body(diagnostics: nil)
        XCTAssertFalse(text.contains(BugReport.diagnosticsFence))
        XCTAssertFalse(text.contains("scene-active"))
        XCTAssertTrue(text.contains("1.0.0"), "the environment block still ships")
    }

    func testTheEnvironmentNamesTheExactBuild() {
        let text = body()
        for expected in ["1.0.0", "42", "deadbee", "macOS 15.6", "Mac"] {
            XCTAssertTrue(text.contains(expected), "environment is missing \(expected)")
        }
    }

    func testSubjectNamesTheKindAndTheBuild() {
        XCTAssertEqual(BugReport.subject(kind: .bug, environment: env),
                       "Chalk bug report - 1.0.0 (42)")
        XCTAssertEqual(BugReport.subject(kind: .feedback, environment: env),
                       "Chalk feedback - 1.0.0 (42)")
    }

    // MARK: - issue URL encoding

    /// `&` ends a query parameter, so an unencoded one silently truncates the
    /// body at the first ampersand the user typed. `.urlQueryAllowed` does
    /// not encode it, which is exactly the trap.
    func testAnAmpersandInTheNotesSurvives() throws {
        let url = try XCTUnwrap(BugReport.newIssueURL(
            base: base, title: "s", body: "Tom & Jerry crashed it"))
        XCTAssertTrue(url.absoluteString.contains("%26"),
                      "unencoded & truncates the body: \(url.absoluteString)")
        XCTAssertFalse(url.absoluteString.contains("Jerry&"))
    }

    /// A `+` in a query is read as a space, so it has to be encoded, or "C++"
    /// arrives as "C  ".
    func testAPlusInTheNotesSurvives() throws {
        let url = try XCTUnwrap(BugReport.newIssueURL(
            base: base, title: "s", body: "crashes on C++ files"))
        XCTAssertTrue(url.absoluteString.contains("%2B"))
    }

    func testNewlinesSurvive() throws {
        let url = try XCTUnwrap(BugReport.newIssueURL(
            base: base, title: "s", body: "one\ntwo"))
        XCTAssertTrue(url.absoluteString.contains("%0A"))
    }

    func testTheRoundTripReturnsWhatWentIn() throws {
        let original = "Tom & Jerry\nC++ & \"quotes\" + a #hash, 100% of the time"
        let url = try XCTUnwrap(BugReport.newIssueURL(
            base: base, title: "s", body: original))
        let decoded = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "body" }?.value)
        XCTAssertEqual(decoded, original)
    }

    func testTheTitleIsAQueryItemOnTheBase() throws {
        let url = try XCTUnwrap(BugReport.newIssueURL(base: base, title: "a & b", body: "b"))
        XCTAssertTrue(url.absoluteString.hasPrefix(base + "?"))
        let title = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "title" }?.value
        XCTAssertEqual(title, "a & b")
    }

    // MARK: - truncation

    func testAShortBodyIsNotTouched() {
        let text = body()
        XCTAssertEqual(BugReport.truncateForURL(text, limit: 100_000), text)
    }

    /// The rule that matters. A user who writes three careful paragraphs and
    /// finds two of them missing will not write a fourth.
    func testTruncationNeverEatsTheUsersOwnWords() {
        // No trailing space: composition trims the notes, so a repeated string
        // ending in one never appears verbatim even in an untruncated body.
        let notes = String(repeating: "My careful description.", count: 40)
        let text = body(notes: notes, diagnostics: String(repeating: "e\n", count: 5_000))
        XCTAssertTrue(text.contains(notes), "the harness itself is wrong")
        let cut = BugReport.truncateForURL(text, limit: 1_500)
        XCTAssertTrue(cut.contains(notes), "the notes were truncated")
    }

    func testTruncationNeverEatsTheEnvironment() {
        let text = body(diagnostics: String(repeating: "e\n", count: 5_000))
        let cut = BugReport.truncateForURL(text, limit: 1_500)
        for expected in ["1.0.0", "deadbee", "macOS 15.6"] {
            XCTAssertTrue(cut.contains(expected), "environment lost \(expected)")
        }
    }

    func testTruncationSaysWhatItDropped() {
        let text = body(diagnostics: String(repeating: "e\n", count: 5_000))
        let cut = BugReport.truncateForURL(text, limit: 1_500)
        XCTAssertTrue(cut.lowercased().contains("trimmed"),
                      "a silently shortened report reads as a complete one: \(cut.suffix(200))")
    }

    func testTruncationActuallyGetsUnderTheLimitWhenItCan() {
        let text = body(diagnostics: String(repeating: "e\n", count: 5_000))
        XCTAssertLessThanOrEqual(BugReport.truncateForURL(text, limit: 1_500).count, 1_500)
    }

    /// Which end of the ring survives is a decision, not an accident: the last
    /// events before the report are the ones nearest whatever the user is
    /// describing. Trimming from the tail would keep the launch sequence and
    /// throw away the moment the bug happened.
    func testTruncationKeepsTheEndOfTheRingNotTheStart() {
        let ring = "OLDEST-EVENT\n" + String(repeating: "filler\n", count: 2_000)
                 + "NEWEST-EVENT\n"
        let cut = BugReport.truncateForURL(body(diagnostics: ring), limit: 1_500)
        XCTAssertTrue(cut.contains("NEWEST-EVENT"),
                      "the events nearest the bug were the ones dropped")
        XCTAssertFalse(cut.contains("OLDEST-EVENT"))
    }

    /// When the notes alone exceed the limit there is nothing left to trim.
    /// Returning the whole thing is right: better a draft the browser
    /// refuses than one this code silently gutted.
    func testNotesLongerThanTheLimitAreStillReturnedWhole() {
        let notes = String(repeating: "x", count: 4_000)
        let text = body(notes: notes, diagnostics: "e\n")
        XCTAssertTrue(BugReport.truncateForURL(text, limit: 1_000).contains(notes))
    }

    // MARK: - the privacy claim

    /// The Privacy screen says a report contains no file names, paths or text.
    /// Nothing in composition may take a path, and nothing it assembles may
    /// look like one.
    func testTheComposedBodyContainsNoPathSeparator() {
        let text = body(notes: "it broke")
        for suspicious in ["/Users", ".md", ".tex", "/Volumes"] {
            XCTAssertFalse(text.contains(suspicious),
                           "the report body contains \(suspicious)")
        }
    }
}
