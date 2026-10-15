import AppKit
import ChalkKit

/// One editor window. The titlebar is transparent and the content view runs
/// under it: the tab strip is Chalk's own view pinned to the top of the content
/// (plan decision 4), so there is one tab row for windowed and full screen.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    /// Fired after the window closes, so the owner can drop this controller.
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: EditorWindowController.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = EditorWindowController.minimumSize
        window.backgroundColor = .chalkEditorBackground
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = RootViewController()
        // Assigning a content view controller resizes the window to its view's
        // frame (zero here, clamped to minSize); restore the opening size.
        window.setContentSize(EditorWindowController.defaultSize)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// First-window size and the floor below which the chrome stops being
    /// coherent. Spec values in Mac points (no Catalyst idiom scale).
    static let defaultSize = NSSize(width: 1100, height: 760)
    static let minimumSize = NSSize(width: 640, height: 400)

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// The window's content. Phase 1: one web surface on one document (Welcome),
/// enough to prove the sandboxed bundle load and the transport. The editor
/// container with tabs replaces this in phase 2.
final class RootViewController: NSViewController {
    private let surface = WebEditorSurface()
    private lazy var document = DocumentController(surface: surface)

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let editor = surface.view
        editor.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editor.topAnchor.constraint(equalTo: view.topAnchor),
            editor.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        surface.setAppearance(
            dark: NSApp.effectiveAppearance.isChalkDark, theme: Preferences.colorTheme)
        surface.setChromeTopInset(ChromeMetrics.headerHeight + ChromeMetrics.editorRestingPad)
        document.open(url: SampleContent.ensureSeeded())
        surface.bootIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        surface.focusEditor()
    }
}
