import AppKit
import ChalkKit

/// The swap seam between the native shell and the editor engine, so the shell never touches
/// `WKWebView`. It mirrors `HostPort`: host-to-editor messages are methods, the rest delegate calls.
protocol EditorSurface: AnyObject {
    /// The view to embed in the editor container.
    var view: NSView { get }
    var delegate: EditorSurfaceDelegate? { get set }

    // Host to editor. `theme-colors` is absent: the native shell themes through `data-theme` and
    // `data-palette`.
    // It stays in `HostProtocol` because VS Code sends it.
    func initialize(text: String, language: EditorLanguage, editorConfig: JSONValue?)
    func update(text: String)
    func setHeadingColors(_ colors: HeadingColors)
    func setEditorConfig(_ config: JSONValue)
    func setHsnips(content: String)

    /// Light/dark and the colour theme. Not a HostPort message.
    func setAppearance(dark: Bool, theme: ChalkTheme)

    /// Editor text zoom (1.0 = base size).
    func setFontScale(_ scale: Double)

    /// Focus the editor's text input.
    func focusEditor()

    /// Release the keyboard, including the page's DOM focus: without it WebKit re-asserts first
    /// responder after the overlay takes it and the overlay's text field loses the grab.
    func blurEditor()

    /// Outline and cursor line, pulled when the palette opens. Not a HostPort message.
    /// Completes with nil when the editor isn't up.
    func fetchOutline(completion: @escaping (OutlineSnapshot?) -> Void)

    /// Move the cursor to a 1-based line, scroll it toward the viewport top, and focus the editor.
    func revealLine(_ line: Int)
    /// A bitmap of what the surface shows right now, for the tab switch's cross-fade; nil when
    /// nothing is up. Not a HostPort message.
    func captureSnapshot(_ completion: @escaping (NSImage?) -> Void)
    /// Calls back once the page has painted twice (two animation frames): the gate a covered
    /// transition waits on before lifting its cover. A fixed delay would race the async repaint.
    func afterNextPaint(_ completion: @escaping () -> Void)

    /// Live, debounced outline pushes to `onOutline` for the persistent panel. Off installs no
    /// listener, so keystrokes pay nothing.
    func setOutlineSubscription(_ on: Bool)
    var onOutline: ((OutlineSnapshot) -> Void)? { get set }

    // MARK: Shell-owned presentation
    //
    // Not HostPort messages: the native shell decides these for whatever surface a tab holds.

    /// Bring the surface up. Tabs stay dormant until first shown, sparing a web content process
    /// per background tab.
    func bootIfNeeded()

    /// The overlay band's height: the text rests this far down and scrolls under the band.
    func setChromeTopInset(_ points: Double)
    /// The same, glided over `duration` (docs/motion.md). A surface may forward to the instant one.
    func setChromeTopInset(_ points: Double, animatedOverSeconds duration: TimeInterval)
    /// The text column's own width (the measure), in px.
    func setMeasure(_ px: Double)
    /// Interline spacing, as a multiple of the line height.
    func setLineHeight(_ multiplier: Double)
    /// Wrapped-prose alignment.
    func setTextAlign(_ alignment: EditorTextAlignment)

    /// Scroll-offset reports; drive the chrome auto-hide.
    var onScroll: ((Double) -> Void)? { get set }

    /// Boot recovery is exhausted. A closure, since the delegate is `DocumentController` and this
    /// is a shell concern.
    var onFailedToBecomeReady: (() -> Void)? { get set }

    /// Detach listeners and tear down the underlying view.
    func teardown()
}

/// Editor-to-host callbacks: the 3 outbound HostPort messages plus transport-internal requests.
protocol EditorSurfaceDelegate: AnyObject {
    func editorDidBecomeReady(_ surface: EditorSurface)
    /// The surface lost its editor and is reloading; seed again on the next `editorDidBecomeReady`.
    func editorDidResetConnection(_ surface: EditorSurface)
    func editor(_ surface: EditorSurface, didEdit text: String)
    func editor(_ surface: EditorSurface, requestsOpenExternal url: URL)
    /// Resolve an image `src` to a loadable URL (typically `data:`), or nil.
    func editor(_ surface: EditorSurface, resolveAsset src: String) async -> String?
    /// Document-relative paths for path and citation completion. Empty without a directory scope
    /// (a file opened from Finder is scoped to itself).
    func editor(
        _ surface: EditorSurface,
        listFiles kinds: [WorkspaceFileKind]
    ) async -> [String]
    /// Text of a document-relative file, for `.bib` parsing. Nil when unreadable or too large.
    func editor(_ surface: EditorSurface, readText path: String) async -> String?
    /// Typeset a TikZ widget's standalone document; nil when TeX can't run here.
    func editor(_ surface: EditorSurface, renderTikz document: String) async -> TikzRenderResult?
    /// A shell shortcut the web layer forwarded (e.g. "save" for Cmd+S).
    func editor(_ surface: EditorSurface, requestsCommand name: String)
}

extension EditorSurfaceDelegate {
    func editor(_ surface: EditorSurface, requestsCommand name: String) {}
    func editor(_ surface: EditorSurface, renderTikz document: String) async -> TikzRenderResult? { nil }
    func editorDidResetConnection(_ surface: EditorSurface) {}
}
