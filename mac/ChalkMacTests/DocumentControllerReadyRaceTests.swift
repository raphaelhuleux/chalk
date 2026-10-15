import XCTest
import ChalkKit
@testable import ChalkMac

/// Guards the intermittent "clicking a note opens a blank editor" bug. Root
/// cause: a text `update` can reach the editor before any `init` has built the
/// CM6 view, and the JS side (`mount.ts`) silently discards such an `update` —
/// leaving the tab permanently empty. `DocumentController` must always route an
/// `init` to the editor before (or instead of) a bare `update` for the current
/// editor generation. `FakeEditorSurface.droppedUpdateCount` models the JS drop.
final class DocumentControllerReadyRaceTests: XCTestCase {
    private var surface: FakeEditorSurface!
    private var controller: DocumentController!

    override func setUp() {
        super.setUp()
        surface = FakeEditorSurface()
        controller = DocumentController(surface: surface)
        // NB: unlike the language tests, we do NOT signal ready here — these
        // tests drive the not-ready-yet orderings that trigger the bug.
    }

    override func tearDown() {
        controller = nil
        surface = nil
        super.tearDown()
    }

    /// The reported path: open a note, then browse (reuse) to another same-
    /// language note, all before the webview has signalled `ready`. When ready
    /// finally arrives, the editor must be seeded with an `init` (never a lone
    /// `update`) and show the latest file — not blank.
    func testOpenThenReopenBeforeReadyNeverDropsUpdate() throws {
        let a = try writeTempFile(name: "a.md", contents: "# A\n")
        let b = try writeTempFile(name: "b.md", contents: "# B\n")

        openAndWait(a)   // surface not ready → seed deferred
        reopenAndWait(b) // browse-reuse, same language, still not ready

        surface.signalReady()

        XCTAssertEqual(surface.droppedUpdateCount, 0,
                       "no update may reach the editor before an init built the view")
        XCTAssertEqual(surface.displayedText, "# B\n",
                       "the editor must show the note that was opened, not stay blank")
        XCTAssertFalse(surface.initializeLanguages.isEmpty,
                       "the editor must be seeded with an init")
    }

    /// After the web content process is killed and reloaded, an external file
    /// change (foreground reload) must re-seed via `init`, not push a bare
    /// `update` into the not-yet-rebuilt editor.
    func testExternalReloadAfterProcessResetReinitializes() throws {
        let url = try writeTempFile(name: "notes.md", contents: "# One\n")

        surface.signalReady()
        openAndWait(url)
        XCTAssertEqual(surface.displayedText, "# One\n")

        surface.simulateProcessReset() // view gone, awaiting a fresh `ready`

        try overwrite(url, contents: "# One\n# Two (external)\n")
        controller.reloadIfChangedExternally() // async coordinated read + push

        surface.signalReady()

        // The coordinated read runs on a utility queue and pushes on a main
        // hop; wait for the adoption to land before asserting.
        let adopted = expectation(description: "external change adopted")
        surface.onDisplayedTextChange = { text in
            if text == "# One\n# Two (external)\n" { adopted.fulfill() }
        }
        wait(for: [adopted], timeout: 5)
        surface.onDisplayedTextChange = nil

        XCTAssertEqual(surface.droppedUpdateCount, 0,
                       "an external reload after a reset must not drop content")
        XCTAssertEqual(surface.displayedText, "# One\n# Two (external)\n",
                       "the reloaded external change must be visible, not blank")
    }

    /// A same-language reopen while the editor is already up keeps the cheap
    /// minimal-diff `update` path (no needless view rebuild) — and still drops
    /// nothing.
    func testSameLanguageReopenWhileReadyUsesUpdate() throws {
        let a = try writeTempFile(name: "a.md", contents: "# A\n")
        let b = try writeTempFile(name: "b.md", contents: "# B\n")

        surface.signalReady()
        openAndWait(a)
        reopenAndWait(b)

        XCTAssertEqual(surface.droppedUpdateCount, 0)
        XCTAssertEqual(surface.updateTexts, ["# B\n"],
                       "a same-language reopen with a live editor should use update")
        XCTAssertEqual(surface.displayedText, "# B\n")
    }

    // MARK: - Helpers

    private func writeTempFile(name: String, contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    /// Overwrite a file and force a strictly-later modification date, so
    /// `reloadIfChangedExternally`'s `onDisk > synced` check fires regardless of
    /// filesystem timestamp granularity.
    private func overwrite(_ url: URL, contents: String) throws {
        try contents.data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
    }

    private func openAndWait(_ url: URL) {
        let spy = DirtySpy()
        controller.delegate = spy
        let done = expectation(description: "open \(url.lastPathComponent)")
        spy.onDirtyChange = { _ in done.fulfill() }
        controller.open(url: url)
        wait(for: [done], timeout: 5)
    }

    private func reopenAndWait(_ url: URL) {
        let spy = DirtySpy()
        controller.delegate = spy
        let done = expectation(description: "reopen \(url.lastPathComponent)")
        spy.onDirtyChange = { _ in done.fulfill() }
        controller.reopen(url: url)
        wait(for: [done], timeout: 5)
    }
}
