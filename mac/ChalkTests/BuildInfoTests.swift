import XCTest
@testable import Chalk
import ChalkKit

/// What this binary is, read once from its own Info.plist.
///
/// The stamps are injected at build time, so every field can be absent, empty,
/// or the literal `$(CHALK_...)` if the build setting is ever undeclared. Each
/// has to resolve to something a person can read, because these values
/// end up in a bug report subject line and in the About box, where "?" is a
/// worse answer than a wrong-looking one but a crash is the worst of all.
final class BuildInfoTests: XCTestCase {
    private func info(_ pairs: [String: String]) -> BuildInfo {
        BuildInfo(infoDictionary: pairs)
    }

    func testReadsTheVersionAndBuild() {
        let build = info(["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "42"])
        XCTAssertEqual(build.appVersion, "1.0.0")
        XCTAssertEqual(build.build, "42")
    }

    func testAMissingKeyBecomesAReadablePlaceholderNotACrash() {
        let build = info([:])
        XCTAssertEqual(build.appVersion, "?")
        XCTAssertEqual(build.build, "?")
        XCTAssertEqual(build.commit, "unstamped")
    }

    /// An undeclared build setting reaches the built plist as its own literal.
    /// Showing "$(CHALK_GIT_COMMIT)" in About tells the user the build is
    /// broken in a way they cannot act on; "unstamped" is the true statement.
    func testAnUnexpandedBuildSettingReadsAsUnstamped() {
        XCTAssertEqual(info(["CHALKGitCommit": "$(CHALK_GIT_COMMIT)"]).commit, "unstamped")
        XCTAssertEqual(info(["CHALKGitCommit": ""]).commit, "unstamped")
        XCTAssertEqual(info(["CHALKGitCommit": "   "]).commit, "unstamped")
    }

    func testAStampedCommitSurvives() {
        XCTAssertEqual(info(["CHALKGitCommit": "deadbee"]).commit, "deadbee")
    }

    /// The real bundle must not crash or produce empty strings, whatever the
    /// test host was built with.
    func testTheRunningBundleAnswersEveryField() {
        let build = BuildInfo.current
        XCTAssertFalse(build.appVersion.isEmpty)
        XCTAssertFalse(build.build.isEmpty)
        XCTAssertFalse(build.commit.isEmpty)
    }

    /// The report environment is assembled from this and nothing else, so a
    /// field that goes missing here goes missing from every bug report.
    func testItComposesAReportEnvironmentWithNoEmptyFields() {
        let environment = info(["CFBundleShortVersionString": "1.0.0",
                                "CFBundleVersion": "42",
                                "CHALKGitCommit": "deadbee"]).reportEnvironment
        XCTAssertEqual(environment.appVersion, "1.0.0")
        XCTAssertEqual(environment.build, "42")
        XCTAssertEqual(environment.commit, "deadbee")
        XCTAssertFalse(environment.systemVersion.isEmpty)
        XCTAssertFalse(environment.model.isEmpty)
        XCTAssertFalse(environment.locale.isEmpty)
    }
}
