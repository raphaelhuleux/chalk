import XCTest
import ChalkKit
@testable import ChalkMac

/// The three transport-internal requests (`resolve-asset`, `list-files`,
/// `read-text`) share one reply path: the delegate's answer, JSON-encoded, or
/// `null`, handed back to the page under the request's id.
@MainActor
final class WebEditorSurfaceReplyTests: XCTestCase {
    private var surface: WebEditorSurface!
    private var answerer: Answerer!

    override func setUp() {
        super.setUp()
        surface = WebEditorSurface()
        answerer = Answerer()
        surface.delegate = answerer
    }

    override func tearDown() {
        surface.teardown()
        surface = nil
        answerer = nil
        super.tearDown()
    }

    private func waitForScript(_ script: String) {
        let deadline = Date().addingTimeInterval(5)
        while !surface.evaluatedScriptsForTesting.contains(script), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(surface.evaluatedScriptsForTesting.contains(script),
                      "expected \(script), got \(surface.evaluatedScriptsForTesting)")
    }

    func testEachRequestIsAnsweredUnderItsId() {
        surface.handleHostMessage(body: ["type": "list-files", "id": 1, "kinds": ["bib"]])
        surface.handleHostMessage(body: ["type": "read-text", "id": 2, "path": "refs.bib"])
        surface.handleHostMessage(body: ["type": "resolve-asset", "id": 3, "src": "fig.png"])

        waitForScript(#"window.__chalkHost.listFilesReply(1, ["refs.bib"])"#)
        waitForScript(#"window.__chalkHost.readTextReply(2, "@book{x}")"#)
        waitForScript(#"window.__chalkHost.resolveAssetReply(3, "data:fig.png")"#)
        XCTAssertEqual(answerer.listedKinds, [[.bib]])
    }

    func testAMissingAnswerIsNull() {
        answerer.hasAnswers = false
        surface.handleHostMessage(body: ["type": "read-text", "id": 4, "path": "missing.bib"])
        waitForScript("window.__chalkHost.readTextReply(4, null)")
    }

    func testNoDelegateStillSettlesTheRequest() {
        surface.delegate = nil
        surface.handleHostMessage(body: ["type": "resolve-asset", "id": 5, "src": "fig.png"])
        waitForScript("window.__chalkHost.resolveAssetReply(5, null)")
    }
}

private final class Answerer: EditorSurfaceDelegate {
    var hasAnswers = true
    private(set) var listedKinds: [[WorkspaceFileKind]] = []

    func editorDidBecomeReady(_ surface: EditorSurface) {}
    func editor(_ surface: EditorSurface, didEdit text: String) {}
    func editor(_ surface: EditorSurface, requestsOpenExternal url: URL) {}
    func editor(_ surface: EditorSurface, resolveAsset src: String) async -> String? {
        hasAnswers ? "data:\(src)" : nil
    }
    func editor(_ surface: EditorSurface, listFiles kinds: [WorkspaceFileKind]) async -> [String] {
        listedKinds.append(kinds)
        return ["refs.bib"]
    }
    func editor(_ surface: EditorSurface, readText path: String) async -> String? {
        hasAnswers ? "@book{x}" : nil
    }
}
