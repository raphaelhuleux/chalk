import XCTest
import WebKit
import ChalkKit
@testable import ChalkMac

/// Editor config, heading colours and snippets are latest-value state on the
/// web surface, not queued messages. Before `ready` only the newest value is
/// kept; on `ready` each goes out once, ahead of the `init` that builds the
/// view, so the first view is built with the right config instead of built
/// with defaults and reconfigured.
@MainActor
final class WebEditorSurfaceSettingsTests: XCTestCase {
    private var surface: WebEditorSurface!
    private var seeder: SeedingDelegate!

    override func setUp() {
        super.setUp()
        surface = WebEditorSurface()
        seeder = SeedingDelegate()
        surface.delegate = seeder
    }

    override func tearDown() {
        surface.teardown()
        surface = nil
        seeder = nil
        super.tearDown()
    }

    private func config(_ mode: String) -> JSONValue {
        .object(["editingMode": .string(mode)])
    }

    private func signalReady() {
        surface.handleHostMessage(body: ["type": "ready"])
    }

    func testSettingsBeforeReadyGoOutOnceAheadOfTheSeed() {
        // A dormant tab through a Settings slider drag: many values, one kept.
        for mode in ["normal", "focus", "source"] {
            surface.setEditorConfig(config(mode))
            surface.setHeadingColors(HeadingColors(h1: mode))
            surface.setHsnips(content: "snippets-\(mode)")
        }

        signalReady()

        XCTAssertEqual(surface.deliveredMessagesForTesting, [
            .editorConfig(config("source")),
            .headingColors(HeadingColors(h1: "source")),
            .hsnips(content: "snippets-source"),
            .initialize(text: "doc", language: .md, editorConfig: nil, epoch: 1),
        ], "latest settings once each, then the seed; no reconfigure after it")
    }

    func testSettingsAfterReadyGoOutImmediately() {
        signalReady()
        let seeded = surface.deliveredMessagesForTesting.count

        surface.setEditorConfig(config("source"))
        surface.setHsnips(content: "edited")

        XCTAssertEqual(Array(surface.deliveredMessagesForTesting.dropFirst(seeded)), [
            .editorConfig(config("source")),
            .hsnips(content: "edited"),
        ])
    }

    /// Settings pushes every setting to every tab on each slider tick; only
    /// what changed may reach the page.
    func testUnchangedValuesAreNotResent() {
        signalReady()
        let messages = surface.deliveredMessagesForTesting.count
        let scripts = surface.evaluatedScriptsForTesting.count

        for _ in 0..<3 {
            surface.setEditorConfig(config("source"))
            surface.setHeadingColors(HeadingColors(h1: "#123456"))
            surface.setHsnips(content: "snippets")
            surface.setFontScale(1.2)
            surface.setMeasure(700)
            surface.setLineHeight(1.6)
            surface.setTextAlign(.justified)
        }

        XCTAssertEqual(surface.deliveredMessagesForTesting.count - messages, 3,
                       "config, colours and snippets once each")
        let css = surface.evaluatedScriptsForTesting.dropFirst(scripts)
            .filter { $0.hasPrefix("document.documentElement.style.setProperty") }
        XCTAssertEqual(css.count, 4, "font size, measure, line height and alignment once each")
    }

    /// A crashed web content process loses the page and everything it held.
    /// The reloaded page's `ready` must get the settings again, although the
    /// values have not changed.
    func testReloadedPageGetsTheSettingsAgain() throws {
        surface.setEditorConfig(config("source"))
        surface.setHsnips(content: "snippets")
        signalReady()

        let webView = try XCTUnwrap(surface.view as? WKWebView)
        surface.webViewWebContentProcessDidTerminate(webView)
        let before = surface.deliveredMessagesForTesting.count
        signalReady()

        XCTAssertEqual(Array(surface.deliveredMessagesForTesting.dropFirst(before)), [
            .editorConfig(config("source")),
            .hsnips(content: "snippets"),
            .initialize(text: "doc", language: .md, editorConfig: nil, epoch: 2),
        ])
    }

    func testReloadedPageGetsTheStyleSettingsAgain() throws {
        surface.setMeasure(700)
        surface.setTextAlign(.justified)
        signalReady()

        let webView = try XCTUnwrap(surface.view as? WKWebView)
        surface.webViewWebContentProcessDidTerminate(webView)
        surface.setMeasure(700) // the same value, while the page reloads
        let before = surface.evaluatedScriptsForTesting.count
        signalReady()

        let css = surface.evaluatedScriptsForTesting.dropFirst(before)
        XCTAssertEqual(css.filter { $0.contains("--chalk-measure', '700px'") }.count, 1)
        XCTAssertEqual(css.filter { $0.contains("--chalk-text-align', 'justify'") }.count, 1)
    }
}

/// Seeds on `ready` the way DocumentController does.
private final class SeedingDelegate: EditorSurfaceDelegate {
    func editorDidBecomeReady(_ surface: EditorSurface) {
        surface.initialize(text: "doc", language: .md, editorConfig: nil)
    }
    func editor(_ surface: EditorSurface, didEdit text: String) {}
    func editor(_ surface: EditorSurface, requestsOpenExternal url: URL) {}
    func editor(_ surface: EditorSurface, resolveAsset src: String) async -> String? { nil }
    func editor(_ surface: EditorSurface, listFiles kinds: [WorkspaceFileKind]) async -> [String] { [] }
    func editor(_ surface: EditorSurface, readText path: String) async -> String? { nil }
}
