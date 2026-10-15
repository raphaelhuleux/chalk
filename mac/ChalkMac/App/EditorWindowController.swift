import AppKit
import ChalkKit

/// One editor window. The titlebar is transparent and the content view runs
/// under it: the tab band is Chalk's own view pinned to the top of the content
/// (plan decision 4), so there is one tab row for windowed and full screen.
///
/// An empty unified toolbar gives the titlebar its tall form with the traffic
/// lights centered in it; nothing else of the toolbar is used, and the band
/// under it takes the clicks.
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    /// Fired after the window closes, so the owner can drop this controller.
    var onClose: (() -> Void)?

    let root: RootSplitViewController

    init(initialContent: SceneConnectContent = .openWelcome,
         locationStore: LocationStore = .detached()) {
        root = RootSplitViewController(locationStore: locationStore, initialContent: initialContent)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: EditorWindowController.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentMinSize = ChalkMetrics.minWindowSize
        window.backgroundColor = .chalkEditorBackground
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "chalk.titlebar")
        toolbar.delegate = self
        toolbar.showsBaselineSeparator = false
        toolbar.displayMode = .iconOnly
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        window.delegate = self
        window.contentViewController = root
        // Assigning a content view controller resizes the window to its view's
        // frame (zero here, clamped to minSize); restore the opening size.
        window.setContentSize(EditorWindowController.defaultSize)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// First-window size, in Mac points.
    static let defaultSize = NSSize(width: 1100, height: 760)

    func windowWillClose(_ notification: Notification) {
        root.releaseExternalScopes()
        onClose?()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        root.setMacFullscreen(true)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        root.setMacFullscreen(false)
    }

    func windowDidResignKey(_ notification: Notification) {
        // No autosave: the window losing focus is the one automatic flush.
        root.saveAllDocuments()
        root.snapshotDirtyBuffers()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        root.reloadExternalChanges()
    }

    // MARK: NSToolbarDelegate (an empty toolbar: the titlebar's height is all it is for)

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
}
