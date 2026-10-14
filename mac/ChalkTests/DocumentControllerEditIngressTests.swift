import XCTest
import ChalkKit
@testable import Chalk

/// The buffer is what `save()` writes. So the buffer must only ever accept
/// text while it actually corresponds to a loaded document, otherwise a
/// controller left in a failed or transitional state becomes a live write
/// target aimed at the wrong file.
final class DocumentControllerEditIngressTests: XCTestCase {
    private var surface: FakeEditorSurface!
    private var controller: DocumentController!
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        surface = FakeEditorSurface()
        controller = DocumentController(surface: surface)
        surface.signalReady()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-ingress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        controller = nil
        surface = nil
        try super.tearDownWithError()
    }

    private func settle(_ seconds: TimeInterval = 1.0) {
        let done = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 4)
    }

    func testAnEditAfterAFailedOpenIsRefused() throws {
        // A directory named like a document: ChalkDocument refuses it, so the
        // open fails and nothing is loaded.
        let target = root.appendingPathComponent("notes.md")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        controller.open(url: target)
        settle()

        controller.editor(surface, didEdit: "text the user typed into a dead tab")

        XCTAssertFalse(controller.isDirty)
        XCTAssertEqual(controller.currentText, "")
    }

    /// A draft has no file on disk but is legitimately editable, so the guard
    /// must not catch it. `openDraft` sets isLoaded, which is what makes the
    /// guard safe; this pins that so it cannot later be tightened onto
    /// `document != nil`, which would silently break every draft.
    func testADraftStillAcceptsEdits() {
        controller.openDraft(language: .md, recoveredText: "")

        controller.editor(surface, didEdit: "a draft the user is writing")

        XCTAssertTrue(controller.isDirty)
        XCTAssertEqual(controller.currentText, "a draft the user is writing")
    }

    func testAnOpenedFileStillAcceptsEdits() throws {
        let file = root.appendingPathComponent("real.md")
        try Data("original".utf8).write(to: file)

        controller.open(url: file)
        settle()
        controller.editor(surface, didEdit: "original plus an edit")

        XCTAssertTrue(controller.isDirty)
        XCTAssertEqual(controller.currentText, "original plus an edit")
    }
}
