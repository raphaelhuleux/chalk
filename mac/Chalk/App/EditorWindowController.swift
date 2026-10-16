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

    /// Fired when the window becomes key, for the owner's breadcrumbs.
    var onBecomeKey: (() -> Void)?

    /// The identity this window's Locations and journal record live under
    /// (`WindowLocations.key`, `WindowRecord.id`). Survives restoration.
    let windowID: String

    let root: RootSplitViewController

    /// - Parameters:
    ///   - windowID: a restored window's id, or a fresh one.
    ///   - locationStore: this window's folders; the app delegate hands in the
    ///     per-window store, tests leave it detached.
    ///   - frame: the restored frame in screen coordinates, else the default
    ///     size centred.
    init(windowID: String = UUID().uuidString,
         initialContent: WindowContent = .openWelcome,
         locationStore: LocationStore = .detached(),
         frame: NSRect? = nil) {
        self.windowID = windowID
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
        if let frame, frame.width >= ChalkMetrics.minWindowSize.width,
           frame.height >= ChalkMetrics.minWindowSize.height {
            window.setFrame(frame, display: false)
            // A frame from a display that is gone lands off screen.
            if window.screen == nil { window.center() }
        } else {
            window.center()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// First-window size, in Mac points.
    static let defaultSize = NSSize(width: 1100, height: 760)

    /// What the journal keeps for this window: its id, its tabs and its frame.
    /// In full screen the frame is the screen, so the one from before the
    /// episode is kept: a relaunch opens a window, not a screen-sized one.
    func windowRecord() -> WindowRecord {
        var frame: WindowRecord.Frame?
        if let rect = frameBeforeFullScreen ?? window?.frame {
            frame = WindowRecord.Frame(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        }
        return WindowRecord(id: windowID, session: root.captureSession(), frame: frame)
    }

    /// The windowed frame while in full screen, nil otherwise.
    private var frameBeforeFullScreen: NSRect?

    /// The red close button is the user's "done with this": it saves, or the
    /// window's edits would drain into another window at the next launch. The scopes release only after the
    /// async writes land: revoking a sandbox extension mid-write fails the save.
    func windowWillClose(_ notification: Notification) {
        let root = self.root
        root.snapshotDirtyBuffers()
        root.saveAllDocuments { root.releaseExternalScopes() }
        onClose?()
    }

    /// The empty toolbar exists for the tall windowed titlebar. In full screen
    /// AppKit keeps a toolbar on screen as an opaque bar at the top, which
    /// would paint over the band; without one the top edge is the band.
    func windowWillEnterFullScreen(_ notification: Notification) {
        frameBeforeFullScreen = window?.frame
        window?.toolbar?.isVisible = false
        root.setMacFullscreen(true)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        window?.toolbar?.isVisible = true
        root.setMacFullscreen(false)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        frameBeforeFullScreen = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // No autosave: the window losing focus is the one automatic flush.
        // Not to its own sheet: a save failure's alert would retry the save
        // and stack a second alert on the first.
        guard window?.attachedSheet == nil else { return }
        root.saveAllDocuments()
        root.snapshotDirtyBuffers()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        root.reloadExternalChanges()
        onBecomeKey?()
    }

    // MARK: NSToolbarDelegate (an empty toolbar: the titlebar's height is all it is for)

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
}
