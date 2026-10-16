import XCTest
import ChalkKit
@testable import Chalk

/// Guards the regression where browsing a `.tex` file into a reused tab (which
/// started on a `.md` file) left the editor in markdown mode — no LaTeX
/// highlighting, `$`-only math. The fix re-initializes the surface (a fresh
/// `init`, which is what switches CM6 into tex mode) whenever a tab-reuse text
/// swap crosses `.md`↔`.tex`.
final class DocumentControllerLanguageTests: XCTestCase {
    private var surface: FakeEditorSurface!
    private var controller: DocumentController!

    override func setUp() {
        super.setUp()
        surface = FakeEditorSurface()
        controller = DocumentController(surface: surface)
        surface.signalReady()
    }

    override func tearDown() {
        controller = nil
        surface = nil
        super.tearDown()
    }

    /// A cross-language rename re-initializes the surface in the new language.
    func testRebindAcrossLanguagesReinitializes() {
        controller.openDraft() // seeds a fresh draft as .md
        XCTAssertEqual(surface.initializeLanguages, [.md])

        controller.rebind(to: URL(fileURLWithPath: "/tmp/notes.tex"))

        XCTAssertEqual(surface.initializeLanguages, [.md, .tex],
                       "renaming .md → .tex should re-init the surface in tex mode")
    }

    /// The save panel can change a draft's extension. Binding the draft to a
    /// file in another language switches the editor's mode, like a rename.
    func testBindDraftAcrossLanguagesReinitializes() {
        controller.openDraft(language: .tex)
        XCTAssertEqual(surface.initializeLanguages, [.tex])

        controller.bindDraft(to: URL(fileURLWithPath: "/tmp/saved.md"), writtenText: "")

        XCTAssertEqual(controller.language, .md)
        XCTAssertEqual(surface.initializeLanguages, [.tex, .md])
    }

    func testBindDraftSameLanguageDoesNotReinitialize() {
        controller.openDraft(language: .tex)
        controller.bindDraft(to: URL(fileURLWithPath: "/tmp/saved.tex"), writtenText: "")

        XCTAssertEqual(surface.initializeLanguages, [.tex])
    }

    /// A same-language rename does NOT re-initialize (no needless view rebuild).
    func testRebindSameLanguageDoesNotReinitialize() {
        controller.openDraft() // .md
        controller.rebind(to: URL(fileURLWithPath: "/tmp/renamed.md"))

        XCTAssertEqual(surface.initializeLanguages, [.md],
                       "a .md → .md rename should not re-init the surface")
    }

    /// The actual reported path: a clean tab on a `.md` file browses to a `.tex`
    /// file via `reopen`. The surface must re-init into tex mode, not just get an
    /// `update`.
    func testReopenMdTabWithTexFileReinitializes() throws {
        let mdURL = try writeTempFile(name: "welcome.md", contents: "# Hello\n")
        let texURL = try writeTempFile(name: "linalg.tex", contents: "\\section{Systems}\n\\[Ax=b\\]\n")

        openAndWait(mdURL)
        XCTAssertEqual(surface.initializeLanguages, [.md])

        reopenAndWait(texURL)

        XCTAssertEqual(surface.initializeLanguages, [.md, .tex],
                       "browsing a .tex into a .md tab should re-init in tex mode")
        XCTAssertTrue(surface.updateTexts.isEmpty,
                      "a cross-language reopen should re-init, not minimal-diff update")
    }

    /// A same-language `reopen` keeps the proven minimal-diff `update` path.
    func testReopenSameLanguageUsesUpdate() throws {
        let firstURL = try writeTempFile(name: "a.md", contents: "# A\n")
        let secondURL = try writeTempFile(name: "b.md", contents: "# B\n")

        openAndWait(firstURL)
        reopenAndWait(secondURL)

        XCTAssertEqual(surface.initializeLanguages, [.md],
                       "a same-language reopen should not re-init")
        XCTAssertEqual(surface.updateTexts, ["# B\n"],
                       "a same-language reopen should push text via update")
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

    /// `open`/`reopen` read the file through `ChalkDocument` asynchronously and then
    /// fire `didChangeDirty` on the delegate; wait on that so assertions see the
    /// completed seed.
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
