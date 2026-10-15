import XCTest
import ChalkKit
import WebKit
@testable import ChalkMac

/// A new tab must not flash the wrong theme before its first paint.
///
/// The bundle's stylesheet declares DARK on bare `:root` and light only under
/// `:root[data-theme="light"]`, and the shell sets that attribute over the
/// bridge — which cannot run until the page has loaded, booted and posted
/// `ready`. So in light mode every freshly booted surface painted a dark
/// editor first and flipped after: the flicker on ⌘N and on the + button.
/// Dark mode hid it, because the default already matched.
///
/// The fix has to land BEFORE first paint, which means a document-start user
/// script rather than an `evaluateJavaScript` on `ready`.
@MainActor
final class WebEditorSurfaceFirstPaintTests: XCTestCase {
    private func documentStartSources(_ surface: WebEditorSurface) -> [String] {
        surface.userScriptsForTesting
            .filter { $0.injectionTime == .atDocumentStart }
            .map(\.source)
    }

    func testLightSurfaceCarriesItsThemeBeforeTheBundleRuns() {
        let surface = WebEditorSurface()
        surface.setAppearance(dark: false, theme: .ink)   // the shell dresses the surface before install
        surface.bootIfNeeded()

        let sources = documentStartSources(surface)
        XCTAssertTrue(
            sources.contains { $0.contains("data-theme") && $0.contains("light") },
            "a light surface must set data-theme=light at document start; got \(sources)")
    }

    func testDarkSurfaceCarriesItsThemeBeforeTheBundleRuns() {
        let surface = WebEditorSurface()
        surface.setAppearance(dark: true, theme: .ink)
        surface.bootIfNeeded()

        let sources = documentStartSources(surface)
        XCTAssertTrue(
            sources.contains { $0.contains("data-theme") && $0.contains("dark") },
            "a dark surface must set data-theme=dark at document start; got \(sources)")
    }

    /// The colour theme rides the same seed: a Catppuccin tab must not paint Ink first.
    func testThemedSurfaceCarriesItsPaletteBeforeTheBundleRuns() {
        let surface = WebEditorSurface()
        surface.setAppearance(dark: true, theme: .catppuccin)
        surface.bootIfNeeded()

        let sources = documentStartSources(surface)
        XCTAssertTrue(
            sources.contains { $0.contains("data-palette', 'catppuccin'") },
            "a Catppuccin surface must set data-palette at document start; got \(sources)")
    }

    /// The seed must not cost the scroll telemetry its own document-start hook.
    func testScrollTelemetryFlagSurvivesTheThemeSeed() {
        let surface = WebEditorSurface()
        surface.setAppearance(dark: false, theme: .ink)
        surface.bootIfNeeded()

        XCTAssertTrue(
            documentStartSources(surface).contains { $0.contains("__chalkWantsScrollTelemetry") },
            "the chrome auto-hide telemetry opt-in must still be injected")
    }

    // MARK: - The white before the first paint

    /// AppKit's WKWebView composites white until the page paints, and the
    /// shell has no public opaque switch: the surface keeps its web view
    /// transparent until `ready`, so the editor-toned host shows instead.
    func testTheWebViewStaysCoveredUntilReady() {
        let surface = WebEditorSurface()
        surface.bootIfNeeded()
        XCTAssertFalse(surface.isWebViewRevealedForTesting, "a booting page must not show its white")
        XCTAssertTrue(surface.webView.isDescendant(of: surface.view), "the web view lives inside the host")
        surface.handleHostMessage(body: ["type": "ready"])
        XCTAssertTrue(surface.isWebViewRevealedForTesting, "ready is the first paint in the editor's tone")
    }

    /// A reload after a web-process crash paints white first, like a boot.
    func testACrashedPageIsCoveredAgainUntilItsNextReady() {
        let surface = WebEditorSurface()
        surface.bootIfNeeded()
        surface.handleHostMessage(body: ["type": "ready"])
        surface.webViewWebContentProcessDidTerminate(surface.webView)
        XCTAssertFalse(surface.isWebViewRevealedForTesting)
        surface.handleHostMessage(body: ["type": "ready"])
        XCTAssertTrue(surface.isWebViewRevealedForTesting)
    }
}
