import XCTest
import ChalkKit
@testable import Chalk

/// The window state line goes to the unified system log with `privacy: .public`
/// (AppDelegate.logState), which is correct for window-shape breadcrumbs and
/// wrong for anything derived from the user's files. `os_log` redaction is
/// per-interpolation, so a public line built from a private source leaks in
/// release builds with no warning anywhere.
///
/// These tests pin the one rule that makes the public annotation safe: every
/// component of `stateSummary` is a count, a flag, or a closed vocabulary.
/// They exist so the Privacy screen's "file names are redacted from logs"
/// claim is checkable rather than asserted.
final class WindowStateLineRedactionTests: XCTestCase {
    private var editor: EditorContainerViewController!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        editor = EditorContainerViewController()
        editor.loadViewIfNeeded()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-redaction-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        editor = nil
        super.tearDown()
    }

    private func writeTempFile(name: String, contents: String = "x\n") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testSummaryNamesTheKindOfTabNotTheFile() throws {
        let url = try writeTempFile(name: "secret-chapter.md")
        editor.open(url: url)

        let summary = editor.diagnosticSummary

        XCTAssertFalse(summary.contains("secret"),
                       "the open document's name reached a log line marked public: \(summary)")
        XCTAssertFalse(summary.contains(".md"),
                       "even the extension narrows what the user is writing: \(summary)")
        XCTAssertTrue(summary.contains("active=file"),
                      "the line must still say a file-backed tab is active: \(summary)")
    }

    func testSummaryStillDistinguishesNoTabFromDraftFromFile() throws {
        XCTAssertTrue(editor.diagnosticSummary.contains("active=none"),
                      "an empty window must be tellable from a window holding a draft")

        editor.newFile()
        XCTAssertTrue(editor.diagnosticSummary.contains("active=draft"),
                      "a draft has no URL and must not read as an empty window")

        editor.open(url: try writeTempFile(name: "a.md"))
        XCTAssertTrue(editor.diagnosticSummary.contains("active=file"))
    }

    /// The guard that survives someone re-adding a name in a different shape:
    /// no component of the summary may be anything but a fixed word or a number.
    func testEveryFieldOfTheSummaryIsAClosedVocabularyOrANumber() throws {
        _ = try writeTempFile(name: "Thesis-draft.tex")
        editor.open(url: try writeTempFile(name: "Thesis-draft.tex"))

        let allowedValues: Set<String> = ["none", "draft", "file", "true", "false", "n/a"]
        for field in editor.diagnosticSummary.split(separator: " ") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                XCTFail("summary field is not key=value: \(field)")
                continue
            }
            let value = String(parts[1])
            XCTAssertTrue(allowedValues.contains(value) || Int(value) != nil,
                          "summary field '\(field)' carries free text; only counts, "
                          + "flags and the closed set \(allowedValues.sorted()) are public-safe")
        }
    }
}
