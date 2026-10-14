import XCTest
import ChalkKit
@testable import Chalk

/// The surface must receive the *composed* hsnips (bundled defaults + user
/// shortcuts via `hsnipsProvider`) once per editor page: on `ready`, and again
/// after a web process reset. The page keeps them across re-inits (mount.ts
/// re-applies its last snippets to every new view), so a re-init must not
/// resend the whole file.
final class DocumentControllerHsnipsTests: XCTestCase {
    private var surface: FakeEditorSurface!
    private var controller: DocumentController!

    override func setUp() {
        super.setUp()
        surface = FakeEditorSurface()
        controller = DocumentController(surface: surface)
        controller.hsnipsProvider = { "COMPOSED-SNIPPETS" }
        surface.signalReady()
    }

    override func tearDown() {
        controller = nil
        surface = nil
        super.tearDown()
    }

    func testSeedSendsProviderContentNotBundle() {
        controller.openDraft()
        XCTAssertEqual(surface.hsnipsContents, ["COMPOSED-SNIPPETS"])
    }

    func testProcessResetResendsCurrentProviderContent() {
        controller.openDraft()

        // Settings edited a snippet while the tab was open: the provider now
        // yields different content, and the re-seed after a crash must pick
        // up the fresh composition, not a stale capture.
        controller.hsnipsProvider = { "COMPOSED-SNIPPETS-V2" }
        surface.simulateProcessReset()
        surface.signalReady()

        XCTAssertEqual(surface.hsnipsContents, ["COMPOSED-SNIPPETS", "COMPOSED-SNIPPETS-V2"])
    }

    func testNilProviderSendsNothing() {
        let surface = FakeEditorSurface()
        let controller = DocumentController(surface: surface)
        controller.hsnipsProvider = { nil }
        surface.signalReady()
        controller.openDraft()
        XCTAssertEqual(surface.hsnipsCallCount, 0)
    }

    /// A language switch re-initializes the view; the page already holds the
    /// snippets, so the 20-odd KB are not sent again.
    func testReinitDoesNotResendSnippets() {
        controller.openDraft()
        controller.rebind(to: URL(fileURLWithPath: "/tmp/notes.tex"))

        XCTAssertEqual(surface.initializeLanguages, [.md, .tex])
        XCTAssertEqual(surface.hsnipsContents, ["COMPOSED-SNIPPETS"])
    }
}
