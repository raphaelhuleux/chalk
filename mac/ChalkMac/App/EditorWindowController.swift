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
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = RootViewController()
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

/// The window's content. Empty in phase 0; the split view, the strip and the
/// editor column arrive in phases 1 to 3.
final class RootViewController: NSViewController {
    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        self.view = view
    }
}
