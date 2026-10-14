import XCTest
@testable import Chalk
import ChalkKit

/// The screen's one unusual feature is that it shows the exact bytes before
/// sending them. That is the whole trust argument for in-app reporting: an app
/// saying "we collect only anonymous diagnostics" is asking to be believed; an
/// app showing you the payload is not asking for anything.
///
/// These tests exist to keep the preview and the payload the same string. A
/// second composition path that drifted by one line would turn a checkable
/// claim into a false one, and nothing about the screen would look different.
final class ReportProblemTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "chalk-report-\(UUID().uuidString)")
    }

    private func screen() -> ReportProblemViewController {
        let controller = ReportProblemViewController(alpha: AlphaSession(
            build: BuildInfo(infoDictionary: [
                "CFBundleShortVersionString": "1.0.0",
                "CFBundleVersion": "42",
                "CHALKGitCommit": "deadbee",
            ]), defaults: defaults))
        controller.loadViewIfNeeded()
        return controller
    }

    func testThePreviewIsTheBodyByteForByte() {
        let controller = screen()
        controller.notesForTesting = "the window came up empty"
        XCTAssertEqual(controller.previewTextForTesting, controller.composedBody)
    }

    func testThePreviewUpdatesWhenTheNotesDo() {
        let controller = screen()
        controller.notesForTesting = "first"
        XCTAssertTrue(controller.previewTextForTesting.contains("first"))
        controller.notesForTesting = "second"
        XCTAssertTrue(controller.previewTextForTesting.contains("second"))
        XCTAssertFalse(controller.previewTextForTesting.contains("first"))
    }

    /// The switch has to change the payload, not just the label beside it. A
    /// switch that only hides the block from the preview would be a lie in the
    /// most sensitive place in the app.
    func testTurningDiagnosticsOffRemovesThemFromThePayloadNotJustTheView() {
        Diagnostics.record(.recoveryResidueFound, a: 2)
        let controller = screen()

        controller.includeDiagnosticsForTesting = true
        XCTAssertTrue(controller.composedBody.contains(BugReport.diagnosticsFence))
        XCTAssertEqual(controller.previewTextForTesting, controller.composedBody)

        controller.includeDiagnosticsForTesting = false
        XCTAssertFalse(controller.composedBody.contains(BugReport.diagnosticsFence))
        XCTAssertFalse(controller.composedBody.contains("recovery-residue-found"))
        XCTAssertEqual(controller.previewTextForTesting, controller.composedBody)
    }

    func testTheSubjectFollowsTheSelectedKind() {
        let controller = screen()
        controller.kindForTesting = .bug
        XCTAssertTrue(controller.composedSubject.contains("bug report"))
        controller.kindForTesting = .feedback
        XCTAssertTrue(controller.composedSubject.contains("feedback"))
    }

    /// The claim the Privacy screen makes about reports, checked against a
    /// real composed one rather than against the composer in isolation.
    func testAComposedReportNamesNoFileAndNoPath() {
        Diagnostics.record(.launch, a: 1)
        Diagnostics.record(.recoveryPurged, a: 0)
        let controller = screen()
        controller.notesForTesting = "it broke while I was editing"

        let body = controller.composedBody
        for suspicious in ["/Users", "/Volumes", ".md", ".tex", ".qmd", "Untitled"] {
            XCTAssertFalse(body.contains(suspicious),
                           "a composed report contains \(suspicious):\n\(body)")
        }
    }

    /// An empty report is still worth sending: "it crashed, I don't know why"
    /// plus a diagnostics ring is a real bug report.
    func testAReportWithNoNotesStillCarriesTheBuildIdentity() {
        let controller = screen()
        controller.notesForTesting = ""
        XCTAssertTrue(controller.composedBody.contains("deadbee"))
    }
}
