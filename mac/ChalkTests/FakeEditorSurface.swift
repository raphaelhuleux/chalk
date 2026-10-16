import AppKit
import ChalkKit
@testable import Chalk

/// Records the host→editor messages `DocumentController` sends, so tests can
/// assert whether a text swap re-initialized the surface (language/mode change)
/// or took the cheap minimal-diff `update` path. Implements the same
/// `EditorSurface` protocol the real `WebEditorSurface` does.
///
/// It also mirrors the real surface's transport semantics that matter for the
/// empty-editor race: messages sent before the editor signals `ready` are
/// queued and flushed on `ready` (FIFO), and — like `mount.ts` on the JS side —
/// an `update` that reaches the editor before any `init` has built a view is
/// DROPPED. `droppedUpdateCount` counts those drops so a test can assert the
/// controller never lets an `update` outrun the first `init` (the bug that left
/// a freshly-opened note blank).
final class FakeEditorSurface: EditorSurface {
    let view: NSView = NSView()
    weak var delegate: EditorSurfaceDelegate?

    /// Languages passed to each `initialize`, in call order.
    private(set) var initializeLanguages: [EditorLanguage] = []
    /// Texts passed to each `update`, in call order.
    private(set) var updateTexts: [String] = []
    private(set) var hsnipsCallCount = 0
    /// Content passed to each applied `setHsnips`, in call order.
    private(set) var hsnipsContents: [String] = []
    /// Number of `update`s that reached the editor with no view built yet — the
    /// JS side would silently discard these, leaving the editor empty.
    private(set) var droppedUpdateCount = 0
    /// The text the (modelled) editor currently shows: the last `init` text, or
    /// the last non-dropped `update` text. `nil` while the editor is blank.
    private(set) var displayedText: String?

    /// Test hook: fired whenever `displayedText` changes (an applied `init` or
    /// `update`). Lets tests wait for the now-asynchronous external-reload
    /// adoption instead of asserting on a race.
    var onDisplayedTextChange: ((String) -> Void)?

    /// Editor has signalled `ready`; before this, sends queue.
    private var isReady = false
    /// A view exists in the (modelled) JS editor — set by an applied `init`,
    /// torn down on a connection reset. An `update` needs this to render.
    private var viewExists = false
    private var pending: [() -> Void] = []

    func initialize(text: String, language: EditorLanguage, editorConfig: JSONValue?) {
        send { [weak self] in
            self?.viewExists = true
            self?.initializeLanguages.append(language)
            self?.displayedText = text
            self?.onDisplayedTextChange?(text)
        }
    }

    func update(text: String) {
        send { [weak self] in
            guard let self else { return }
            if self.viewExists {
                self.updateTexts.append(text)
                self.displayedText = text
                self.onDisplayedTextChange?(text)
            } else {
                self.droppedUpdateCount += 1
            }
        }
    }

    func setHsnips(content: String) {
        send { [weak self] in
            self?.hsnipsCallCount += 1
            self?.hsnipsContents.append(content)
        }
    }

    // Unused by these tests — no-op conformance.
    func setHeadingColors(_ colors: HeadingColors) {}
    func setEditorConfig(_ config: JSONValue) {}
    func setAppearance(dark: Bool, theme: ChalkTheme) {}
    func setFontScale(_ scale: Double) {}
    func focusEditor() {}
    func blurEditor() {}
    func captureSnapshot(_ completion: @escaping (NSImage?) -> Void) { completion(nil) }
    func afterNextPaint(_ completion: @escaping () -> Void) { DispatchQueue.main.async(execute: completion) }
    func teardown() {}

    // Shell-owned presentation: the container pushes these, and nothing in
    // these tests reads them back.
    func bootIfNeeded() {}
    func setChromeTopInset(_ points: Double) {}
    func setChromeTopInset(_ points: Double, animatedOverSeconds duration: TimeInterval) {}
    func setMeasure(_ px: Double) {}
    func setLineHeight(_ multiplier: Double) {}
    func setTextAlign(_ alignment: EditorTextAlignment) {}
    var onScroll: ((Double) -> Void)?
    var onFailedToBecomeReady: (() -> Void)?

    /// Snapshot handed to `fetchOutline` callers; tests seed it to model a
    /// parsed document. Delivered async to mirror `evaluateJavaScript`.
    var cannedOutline: OutlineSnapshot?
    /// Lines passed to `revealLine`, in call order.
    private(set) var revealedLines: [Int] = []

    func fetchOutline(completion: @escaping (OutlineSnapshot?) -> Void) {
        let snapshot = cannedOutline
        DispatchQueue.main.async { completion(snapshot) }
    }

    func revealLine(_ line: Int) { revealedLines.append(line) }

    var onOutline: ((OutlineSnapshot) -> Void)?
    /// Every subscription flip, in order, so a test can assert handoff.
    private(set) var outlineSubscriptions: [Bool] = []
    func setOutlineSubscription(_ on: Bool) { outlineSubscriptions.append(on) }

    private func send(_ apply: @escaping () -> Void) {
        if isReady { apply() } else { pending.append(apply) }
    }

    /// Drive the `ready` handshake the way the real surface would once its
    /// editor has mounted: notify the controller (which seeds), then flush any
    /// queued messages in order — matching `WebEditorSurface`'s ordering.
    func signalReady() {
        isReady = true
        delegate?.editorDidBecomeReady(self)
        let queued = pending
        pending.removeAll()
        for apply in queued { apply() }
    }

    /// Simulate the web content process being killed and reloaded: the view is
    /// gone, the queue is dropped, and the controller is told to re-seed on the
    /// next `ready`. Mirrors `WebEditorSurface.webViewWebContentProcessDidTerminate`.
    func simulateProcessReset() {
        isReady = false
        viewExists = false
        displayedText = nil
        pending.removeAll()
        delegate?.editorDidResetConnection(self)
    }
}
