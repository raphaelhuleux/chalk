import XCTest
import ChalkKit
@testable import ChalkMac

/// The C-5 edit-epoch gate in the transport: every init/update stamps a text
/// push, the editor echoes the stamp, and an echo carrying a stale epoch is
/// dropped — it was produced against a buffer this surface has since replaced
/// (the keystroke-races-reopen corruption where the OLD document's text became
/// the NEW file's pending edit and overwrote it on the next save).
@MainActor
final class WebEditorSurfaceEpochTests: XCTestCase {
    private var surface: WebEditorSurface!
    private var spy: EditSpy!

    override func setUp() {
        super.setUp()
        surface = WebEditorSurface()
        spy = EditSpy()
        surface.delegate = spy
    }

    override func tearDown() {
        surface.teardown()
        surface = nil
        spy = nil
        super.tearDown()
    }

    func testStaleEpochEditIsDropped() {
        surface.initialize(text: "A", language: .md, editorConfig: nil) // epoch 1
        surface.update(text: "B") // epoch 2 — the reopen/reload buffer swap

        // The in-flight echo produced against epoch 1 arrives after the swap.
        surface.handleHostMessage(body: ["type": "edit", "text": "A + keystroke", "epoch": 1])
        XCTAssertEqual(spy.edits, [], "an edit against a replaced buffer must be dropped")

        surface.handleHostMessage(body: ["type": "edit", "text": "B + keystroke", "epoch": 2])
        XCTAssertEqual(spy.edits, ["B + keystroke"], "a current-epoch edit flows through")
    }

    func testEpochlessEditIsAcceptedForOlderBundles() {
        surface.initialize(text: "A", language: .md, editorConfig: nil)
        surface.handleHostMessage(body: ["type": "edit", "text": "no epoch field"])
        XCTAssertEqual(spy.edits, ["no epoch field"],
                       "a pre-epoch bundle (or VS Code-shaped echo) must keep working")
    }

    func testEveryTextPushBumpsTheEpoch() {
        surface.initialize(text: "A", language: .md, editorConfig: nil)
        XCTAssertEqual(surface.textPushEpoch, 1)
        surface.update(text: "B")
        surface.update(text: "C")
        XCTAssertEqual(surface.textPushEpoch, 3)
        // A re-init (language flip, web-process recovery reseed) is a push too.
        surface.initialize(text: "D", language: .tex, editorConfig: nil)
        XCTAssertEqual(surface.textPushEpoch, 4)
    }
}

private final class EditSpy: EditorSurfaceDelegate {
    private(set) var edits: [String] = []

    func editorDidBecomeReady(_ surface: EditorSurface) {}
    func editor(_ surface: EditorSurface, didEdit text: String) { edits.append(text) }
    func editor(_ surface: EditorSurface, requestsOpenExternal url: URL) {}
    func editor(_ surface: EditorSurface, resolveAsset src: String) async -> String? { nil }
    func editor(_ surface: EditorSurface, listFiles kinds: [WorkspaceFileKind]) async -> [String] { [] }
    func editor(_ surface: EditorSurface, readText path: String) async -> String? { nil }
}
