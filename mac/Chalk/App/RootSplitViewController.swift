import UIKit
import ChalkKit
import os

/// The app root: a two-column split (hideable Library sidebar + editor detail).
///
/// Shell commands (Cmd+J sidebar, P/N/W/S, zoom, tab nav) are defined in
/// `AppDelegate.buildMenu` and route here through the responder chain. Editor
/// keys (typing, Tab tabout, hsnips, Cmd+B/I, Cmd+:) are deliberately not
/// claimed, so they fall through to the web editor.
final class RootSplitViewController: UISplitViewController {
    private(set) var editor = EditorContainerViewController()
    private let sidebar = SidebarViewController()

    /// Shared across windows (the Library is app-level state); injectable so
    /// tests can isolate their own store.
    private let locationStore: LocationStore

    // The tab name row. Hosted here, not in either column, so nothing moves
    // when the sidebar opens. The split columns lay out below it via
    // `additionalSafeAreaInsets`.
    private let headerBar = HeaderBarView()
    private var headerHeight: NSLayoutConstraint?

    /// The floating glass utility pill in the bottom-leading corner. It stands
    /// in every state: nothing sets `footerBar.isHidden`,
    /// only the auto-hide transform and alpha move. The Library list keeps a
    /// bottom content inset so no row scrolls under it.
    private let footerBar = FooterBarView()

    // Quick Open (Cmd+O) and the outline palette (Cmd+P) are in-window
    // overlays, not modal sheets: each is a `PaletteOverlayHost`. They are
    // mutually exclusive (presenting one hides the other), which is this
    // class's rule, not the host's.
    private let quickOpenHost = PaletteOverlayHost()
    private let outlineHost = PaletteOverlayHost()
    /// Active tab id as last reported by `onTabsChanged` (nil = no tabs).
    /// Tracked so the outline palette can tie its snapshot to a tab identity.
    private var currentActiveTabID: UUID?
    /// The tab the outline palette's snapshot belongs to, captured at present
    /// time (nil = opened with no tab). If the active tab changes while the
    /// palette is up, Enter would jump the new tab to the old document's lines,
    /// so `handleTabsChanged` hides the palette on mismatch and `onJump`
    /// refuses a mismatched jump. Not cleared on hide: the jump path hides
    /// first, then jumps, and must still pass the identity check.
    private var outlineSnapshotTabID: UUID?
    /// Bumped per palette open; a fetch completion from a previous open that
    /// lands after a quick close/reopen (one bridge round trip) is dropped
    /// instead of overwriting the fresh tab's snapshot.
    private var outlineFetchGeneration = 0
    /// Per-command timestamp of the last admitted shell dispatch — see
    /// `admitShellAction`.
    private var lastShellDispatch: [Selector: CFTimeInterval] = [:]

    /// The in-flight settle masking the post-slide reflow — held so a rapid
    /// re-toggle can cancel it (see `settleSidebarSlide` / `WebPaintGate`).
    private var sidebarSlideSettle: WebPaintGate?
    /// The column view mid-slide, for `cancelSidebarSlide` to reset.
    private var slidingSidebarColumn: UIView?
    /// Bumped at every slide start (via `cancelSidebarSlide`), so the
    /// completion of a canceled slide cannot run its settle into the new slide
    /// and unfreeze the width mid-slide.
    private var sidebarSlideEpoch = 0
    #if DEBUG
    /// Contract-test seams (SidebarSlideContractTests): replace the webview
    /// snapshot and paint gate so a tabless test root can drive a full
    /// settle — including a dead snapshotter and a held one.
    var sidebarSnapshotterForTesting: WebPaintGate.Snapshotter?
    var sidebarPaintGateForTesting: WebPaintGate.PaintGate?
    #endif

    /// The in-flight appearance cover (docs/motion.md "Appearance"), held so a
    /// rapid theme re-toggle cancels it instead of letting an old cover fade
    /// over the newer transition's pixels.
    private var appearanceSettle: WebPaintGate?
    /// True exactly while the covered transition's own override write runs,
    /// so the root's trait hook can tell its own echo from a genuine system
    /// appearance flip.
    private var isApplyingThemeOverride = false
    #if DEBUG
    /// Contract-test seams (AppearanceTransitionContractTests): the same
    /// shape as the sidebar slide's, forcing the covered path on a tabless
    /// root and making the ordering probe deterministic.
    var appearanceSnapshotterForTesting: WebPaintGate.Snapshotter?
    var appearancePaintGateForTesting: WebPaintGate.PaintGate?
    var appearanceTimingForTesting: WebPaintGate.Timing?
    /// Ordered events of the covered transition: "cover-installed",
    /// "style-applied" (preference route only), "appearance-pushed".
    /// Settable so a test can clear it between routes (the same shape as
    /// `activateEventTrailForTesting`).
    var appearanceTransitionTrailForTesting: [String] = []
    var isAppearanceCoverActiveForTesting: Bool { appearanceSettle?.isActive ?? false }
    #endif

    /// Current editing mode (persisted). Zen's chrome-hiding is tracked
    /// separately in `isZen` so `applyZenChrome` only touches layout on a
    /// real transition.
    private var editingMode = Preferences.editingMode
    private var isZen = false

    #if DEBUG
    /// Test seam (ChromeTransitionMatrixTests): `.instant` routes the animated
    /// chrome transitions (`animateSidebar`, the auto-hide slide) through their
    /// Reduce Motion branches, so a test settles in two runloop turns. The zen
    /// path is already unanimated.
    enum MotionPolicyForTesting { case system, instant }
    var motionPolicyForTesting: MotionPolicyForTesting = .system {
        // One dial: the tab cross-fade lives in the editor container, which
        // has no view of this policy on its own.
        didSet { editor.motionIsInstantForTesting = motionPolicyForTesting == .instant }
    }
    private var motionIsInstant: Bool { motionPolicyForTesting == .instant }

    /// Harness seam (ChromeMatrixHost): a test-hosted root must not join the
    /// AppKit strip bridge. It shares the NotificationCenter with the real
    /// scene root, so left attached it receives the glue's bind posts,
    /// overwrites the scene's bind token, and can steal the bind, after which
    /// its full-screen cells toggle the real test-runner window's NSToolbar:
    /// safe-area churn under every hosted test window. Recorded decisions (the
    /// bridge's `last*`) still update, so the strip invariants keep their
    /// evidence.
    ///
    /// Mirrored into the bridge, where every gated post reads it.
    var stripBridgeDetachedForTesting = false {
        didSet { macStrip.isDetached = stripBridgeDetachedForTesting }
    }
    #else
    private var motionIsInstant: Bool { false }
    #endif

    /// Whether a chrome transition animates: Reduce Motion and the `.instant`
    /// test policy both take the snap lane.
    private var motionAllowed: Bool {
        !UIAccessibility.isReduceMotionEnabled && !motionIsInstant
    }

    /// Info-level breadcrumbs for a timing-dependent bug, so the trail is on
    /// when it happens
    /// (docs/issues/2026-08-17-fullscreen-drops-when-outline-opens.md).
    private static let outlineLog = Logger(subsystem: "com.huleux.chalk", category: "outline")

    /// A palette is up, so the window behind it is dimmed.
    private var lastStripScrimmed = false

    /// Tell the titlebar strip to dim, or stop dimming, with the window
    /// behind a palette.
    ///
    /// The UIKit scrim covers every chrome UIKit owns, but the windowed tab
    /// row is AppKit in the titlebar, which no UIKit view can cover; without
    /// this the tabs stay lit over a dimmed editor.
    private func postStripScrim(_ scrimmed: Bool) {
        guard lastStripScrimmed != scrimmed else { return }
        lastStripScrimmed = scrimmed // recorded decision; see MacStripBridge.lastFaded
        // The post is the bridge's: `MacStripBridge.sendScrim` reads the
        // decision back through `stripBridgeScrimmed`, so the bind replay can
        // re-send a value the dedupe above would swallow.
        macStrip.sendScrim()
    }

    /// The Catalyst titlebar-strip protocol (see MacStripBridge.swift), driven
    /// from the chrome code below. Assigned in `init` rather than lazily, so
    /// its observers are registered from construction.
    private(set) var macStrip: MacStripBridge!

    /// The bind-token fallback lane, published by SceneDelegate at scene
    /// connect (before the glue's deferred toolbar attach). Forwarded; the
    /// token's whole lifecycle belongs to the bridge.
    func publishBindToken(on scene: UIWindowScene) {
        macStrip.publishBindToken(on: scene)
    }

    /// `locationStore` is this window's own folder list (SceneDelegate builds it from the scene session);
    /// the detached default keeps windows built in tests off the installed app's bookmarks.
    init(locationStore: LocationStore = .detached(), initialContent: SceneConnectContent = .openWelcome) {
        self.locationStore = locationStore
        // Seed before the sidebar's view loads so its first enumeration sees the
        // sample files. Idempotent, so N scenes connecting in one launch is fine.
        let welcome = SampleContent.ensureSeeded()
        super.init(style: .doubleColumn)
        // Editor-first (iA Writer style): the Library is hidden until toggled.
        preferredDisplayMode = .secondaryOnly
        preferredSplitBehavior = .tile
        // The pill owns the sidebar toggle; the system display-mode button
        // would double it (and lands on a second row on Mac).
        displayModeButtonVisibility = .never
        // Resizable Library column; the initial width is the persisted
        // last-used value.
        preferredPrimaryColumnWidth = Preferences.sidebarWidth
        minimumPrimaryColumnWidth = Preferences.sidebarWidthRange.lowerBound
        maximumPrimaryColumnWidth = Preferences.sidebarWidthRange.upperBound

        setViewController(UINavigationController(rootViewController: sidebar), for: .primary)
        setViewController(editor, for: .secondary)

        // iA-style auto-hide: the active editor's scroll offsets drive the
        // chrome (see editorDidScroll).
        editor.onActiveEditorScroll = { [weak self] y in
            self?.editorDidScroll(offset: y)
        }

        // Wire the header strip before the first open() so the initial tab
        // shows up in it (the strip renders fine before it joins the hierarchy).
        editor.onTabsChanged = { [weak self] items in
            self?.handleTabsChanged(items)
        }
        // The bridge's init registers the strip protocol's own observers
        // (`action`, `needsState`, `bind`).
        macStrip = MacStripBridge(host: self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTitlebarBandClick(_:)),
            name: TabStripBridge.titlebarBandClick, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWindowFullScreenChange(_:)),
            name: TabStripBridge.windowFullscreen, object: nil)
        // ⌘P arrives from the glue's AppKit event monitor, the only lane that
        // beats NSTextInputContext while a native text field is editing
        // (docs/issues/2026-08-17-fullscreen-drops-when-outline-opens.md).
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleGlueShellKey(_:)),
            name: TabStripBridge.shellKey, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleGlueMiddleClick(_:)),
            name: TabStripBridge.shellMiddleClick, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTitlebarPointerInBand(_:)),
            name: TabStripBridge.titlebarPointerInBand, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAutoHidePreferenceChange),
            name: Preferences.autoHideChromeDidChange, object: nil)
        headerBar.tabStrip.onSelect = { [weak self] id in self?.editor.selectTab(id: id) }
        headerBar.tabStrip.onClose = { [weak self] id in self?.editor.requestCloseTab(id: id) }
        headerBar.tabStrip.onNew = { [weak self] in self?.cmdNewFile() }
        headerBar.tabStrip.onMove = { [weak self] id, index in self?.editor.moveTab(id: id, to: index) }
        // The pill routes to the same shell commands the menu uses.
        footerBar.onToggleSidebar = { [weak self] in self?.cmdToggleSidebar() }
        footerBar.onQuickOpen = { [weak self] in self?.cmdQuickOpen() }
        footerBar.onOutline = { [weak self] in self?.cmdToggleOutline() }
        footerBar.onSettings = { [weak self] in self?.cmdSettings() }
        footerBar.onSelectEditingMode = { [weak self] mode in self?.setEditingMode(mode) }
        // This window's mode, never the global preference, which belongs to
        // whichever window changed its mode last.
        footerBar.currentEditingMode = { [weak self] in self?.editingMode ?? Preferences.editingMode }
        editor.currentEditingMode = { [weak self] in self?.editingMode ?? Preferences.editingMode }
        // The panel's geometry changed: re-cut the band's trailing hole and
        // re-post the strip's inset so the chips stop at the panel.
        editor.onOutlinePanelLayoutChanged = { [weak self] in
            guard let self else { return }
            self.headerBar.setOutlineHole(self.outlineHole())
            self.pushStripLeadingInset()
        }
        editor.onOutlineResizeHover = { [weak self] inside in
            self?.macStrip.postResizeCursor(inside: inside)
        }
        editor.onShellCommand = { [weak self] name in
            // Web-forwarded shell commands (the native-host.ts keydown lane): a
            // focused webview on Catalyst swallows some shortcuts before the
            // menu and pressesBegan, so the page posts them back up. ChalkKit's
            // ShellCommand is the one list of names (mirrored by SHELL_COMMANDS
            // in web/src/native-host.ts); `save` goes to the document controller
            // instead.
            switch ShellCommand(rawValue: name) {
            case .toggleOutline: self?.cmdToggleOutline()
            case .toggleOutlinePanel: self?.cmdToggleOutlinePanel()
            case .quickOpen: self?.cmdQuickOpen()
            case .save, nil: break
            }
        }

        sidebar.locationsProvider = { [weak self] in self?.locationStore.locations() ?? [] }
        editor.libraryRootsProvider = { [weak self] in self?.libraryRoots ?? [] }
        // The Library's list starts on the chrome floor: it asks, every
        // layout pass, and the host answers from its own live chrome.
        sidebar.treeTopProvider = { [weak self] in self?.libraryTreeTopForLibrary() }
        sidebar.onOpenFile = { [weak self] url in
            guard let self else { return }
            // Browse-reuse: a sidebar click replaces the current tab when it's
            // unmodified, so browsing files doesn't spawn tabs.
            self.openFromLibrary(url)
            if self.displayMode == .oneOverSecondary {
                self.animateSidebar(show: false)
            }
        }
        // Asset rows (image/PDF) never reach the editor: a preview sheet instead.
        // The overlay sidebar stays put — the preview covers it anyway, and
        // collapsing it behind a modal reads as the pane vanishing.
        sidebar.onPreviewFile = { [weak self] url in self?.previewAsset(url) }
        // "Open in New Tab": the browse-reuse that makes clicking through the
        // tree cheap is exactly what this menu item opts out of.
        sidebar.onOpenFileInNewTab = { [weak self] url in
            self?.openFromLibrary(url, inNewTab: true)
        }
        // "Open in New Window": the scene launches empty (SceneLaunchPolicy
        // already routes a new-window request there) and SceneDelegate hands
        // the URL to openExternalDocument once its root exists.
        sidebar.onOpenFileInNewWindow = { url in
            let activity = NSUserActivity(activityType: ChalkActivity.newWindowType)
            activity.userInfo = [ChalkActivity.urlKey: url]
            UIApplication.shared.requestSceneSessionActivation(
                nil, userActivity: activity, options: nil)
        }
        sidebar.onAddLocation = { [weak self] url in
            guard let self, !self.locationStore.add(url: url) else { return }
            self.sidebar.showFileOpFailure(
                "Couldn\u{2019}t add \u{201C}\(url.lastPathComponent)\u{201D} to this window. Try adding the folder again.")
        }
        // A Location whose sandbox bookmark stopped granting access heals in
        // place when the user re-picks its folder ("Grant Access…"). The store
        // broadcasts `.chalkLibraryDidChange`, which reloads every window's
        // sidebar — including this one — so no local reload here.
        sidebar.onReauthorizeLocation = { [weak self] id, url in
            self?.locationStore.reauthorize(id: id, with: url)
        }
        // "Remove from Window" drops the Location's security-scoped bookmark
        // and refreshes the tree. Open tabs from that Location stay open.
        sidebar.onRemoveLocation = { [weak self] id in
            self?.locationStore.remove(id: id)
        }
        // A file created from a sidebar context menu opens in a tab.
        sidebar.onOpenCreatedFile = { [weak self] url in
            self?.editor.open(url: url)
        }
        // A draft (Cmd+N) saved to a location for the first time: surface the
        // new file in every window's tree, not just this one's.
        editor.onDraftSaved = { _ in
            NotificationCenter.default.post(name: .chalkLibraryDidChange, object: nil)
        }
        // A rename or drag-move remaps any open tab under the moved path
        // (keeping unsaved edits) rather than closing it. Broadcast so every
        // window remaps: a rename in window A must not leave window B's tab
        // saving to the dead path. Quick Open re-enumerates from disk on each
        // open, so it needs no invalidation.
        sidebar.onFileMoved = { from, to in
            NotificationCenter.default.post(
                name: .chalkFileDidMove, object: nil,
                userInfo: [ChalkNotificationKey.fromURL: from, ChalkNotificationKey.toURL: to])
        }

        // Cross-window signals. Selector-based observers detach on dealloc.
        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryDidChange),
            name: .chalkLibraryDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(fileDidMove(_:)),
            name: .chalkFileDidMove, object: nil)

        // This root orchestrates the covered appearance transitions and pushes
        // the one data-theme change itself; the container's own trait hook
        // stands down (it would flip the page outside the cover on the system
        // route).
        editor.hostOwnsAppearanceTransitions = true
        // The launch theme is a starting state, not a transition: pin it so
        // the call below only covers a light/dark change, as before themes.
        traitOverrides.chalkTheme = Preferences.colorTheme
        applyThemePreference()
        switch initialContent {
        case .openWelcome:
            editor.open(url: welcome)
        case .openEmpty:
            break // the empty-state view shows until the user opens something
        case .restoreSession(let session):
            applyRestoredSession(session)
        }
    }

    /// Single sink for `editor.onTabsChanged`: redraws the strips and tracks
    /// the active tab id for the outline palette's identity guard. The palette
    /// hides when the active tab changes underneath it (its snapshot is
    /// per-document; Quick Open's index is tab-independent). Dirty-state and
    /// reorder callbacks report the same active id and must not dismiss.
    func handleTabsChanged(_ items: [TabItem]) {
        headerBar.tabStrip.update(items)
        // The Library marks where you are, not just what exists.
        sidebar.setOpenDocument(editor.activeDocumentURL)
        macStrip.updateTabs(items)
        // A tab the reader just opened, closed, or switched to must be
        // visible. Keyed on identity, not on the whole item: the same update
        // arrives on every dirty-marker flip, and typing must not pop the
        // chrome back into a reader's field of view.
        let identities = items.map(\.id)
        if identities != lastTabIdentities
            || items.first(where: \.isActive)?.id != currentActiveTabID {
            lastTabIdentities = identities
            revealChrome()
        }
        currentActiveTabID = items.first(where: \.isActive)?.id
        if outlineHost.isVisible, currentActiveTabID != outlineSnapshotTabID {
            hideOutlinePalette { [weak self] in self?.returnFocusAfterDismiss() }
        }
    }

    @objc private func libraryDidChange() {
        // App-wide notification, fans to every window: coalesced + off-main.
        sidebar.scheduleReload()
    }

    @objc private func fileDidMove(_ note: Notification) {
        guard let from = note.userInfo?[ChalkNotificationKey.fromURL] as? URL,
              let to = note.userInfo?[ChalkNotificationKey.toURL] as? URL else { return }
        editor.handleFileMoved(from: from, to: to)
        // The move changed the on-disk tree every window's sidebar shows.
        sidebar.scheduleReload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The system route: on Auto the OS flips the trait (and the native
        // chrome) under us, so run the covered transition and let the page's
        // slower async repaint happen under a cover. `isApplyingThemeOverride`
        // keeps the preference route's own override write from re-entering
        // here.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (root: Self, previous: UITraitCollection) in
            guard previous.userInterfaceStyle != root.traitCollection.userInterfaceStyle,
                  !root.isApplyingThemeOverride else { return }
            root.runAppearanceTransition(flippingTo: nil)
        }
        // Here, not in init: touching `view` in init loads it mid-init, so
        // viewDidLoad would run before the rest of init had wired anything.
        view.addGestureRecognizer(
            UIHoverGestureRecognizer(target: self, action: #selector(handleChromeHover(_:))))
        // The window is one editor surface; chrome floats above it. Covers any
        // split-view gap the columns don't paint.
        view.backgroundColor = .chalkEditorBackground
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)
        let height = headerBar.heightAnchor.constraint(equalToConstant: ChalkMetrics.headerHeight)
        headerHeight = height
        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            height,
        ])

        // The floating utility pill, pinned to the bottom-leading corner in
        // every state, so it holds one screen position (Y-17).
        footerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footerBar)
        let pillInset = ChalkMetrics.footerPillMargin
        NSLayoutConstraint.activate([
            footerBar.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: pillInset),
            footerBar.bottomAnchor.constraint(
                equalTo: view.bottomAnchor, constant: -pillInset),
            footerBar.widthAnchor.constraint(equalToConstant: footerBar.pillWidth),
            footerBar.heightAnchor.constraint(equalToConstant: ChalkMetrics.footerPillHeight),
        ])

        // The tab row is an AppKit strip in the window's NSToolbar
        // (ChalkAppKitGlue), whose unified titlebar arrives as the system
        // safe-area top. The headerBar stays mounted but hidden, for full
        // screen.
        //
        // Hidden only while the glue actually loaded. If the bundle failed to
        // load (copy-phase regression, signing failure) there is no titlebar
        // strip, so fall back to the UIKit band: keep it visible and reserve
        // its height (viewSafeAreaInsetsDidChange maintains it thereafter).
        headerBar.isHidden = SceneDelegate.isAppKitGlueAvailable
        if !SceneDelegate.isAppKitGlueAvailable {
            additionalSafeAreaInsets.top = ChalkMetrics.headerHeight
        }
        // Only the EDITOR clears the toolbar band; the Library column runs the
        // full window height beside it and the tab chips start at the divider.
        applyBandLayout()
        // Restore a persisted zen mode's chrome state (the mode itself reaches
        // the editors via per-tab config seeding in EditorContainer).
        applyZenChrome(editingMode == .zen)
        // Mount the palette overlays last so their dim backdrops layer above
        // the header, footer, and divider. (The two are mutually exclusive, so
        // their relative z-order never shows.)
        setUpQuickOpenOverlay()
        setUpOutlineOverlay()
        #if DEBUG
        applyAuditStateIfRequested()
        #endif
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // The unified titlebar (traffic lights + tabs) arrives as the
        // window's safe-area top and no custom band stacks below it, so the
        // additional inset is 0. No-glue fallback: the UIKit band is the tab
        // UI, so its height is reserved (and reclaimed by zen).
        let wanted: CGFloat = SceneDelegate.isAppKitGlueAvailable || isZen
            ? 0 : ChalkMetrics.headerHeight
        // Half-point tolerance: writing a fractional inset UIKit rounds away
        // would re-enter this callback forever.
        if abs(additionalSafeAreaInsets.top - wanted) > 0.5 {
            additionalSafeAreaInsets.top = wanted
        }
        applyBandLayout()
    }

    /// Consumed by `applyMacChromePresentation`'s band-presence write while a
    /// zen toggle is the driver, the one presence change that animates
    /// (docs/motion.md "Zen / normal"). Every other presentation pass is
    /// instant, mid window transition.
    private var pendingZenBandFade: TimeInterval?

    /// The titlebar band's height as last reported while chrome was actually
    /// laid out (not overlay-revealed). Seeded with the UIKit header height
    /// so a scene that starts in hidden-chrome full screen still reserves a
    /// plausible band before the first real reading arrives.
    private var lastRealBandHeight: CGFloat = ChalkMetrics.headerHeight

    /// This scene's window is in macOS full screen: the glue hid the system
    /// toolbar (its full-screen host paints an opaque band) and this scene
    /// shows the UIKit tab band instead.
    private var isMacFullscreen = false

    /// Glue-forwarded shortcut (⌘P monitor). Routed by window number so only
    /// the scene the keystroke belongs to toggles.
    @objc private func handleGlueShellKey(_ note: Notification) {
        guard macStrip.isAddressedToBoundWindow(note),
              note.userInfo?[TabStripBridge.nameKey] as? String
                == ShellCommand.toggleOutline.rawValue else { return }
        cmdToggleOutline()
    }

    @objc private func handleWindowFullScreenChange(_ note: Notification) {
        guard macStrip.isAddressedToBoundWindow(note),
              let on = note.userInfo?[TabStripBridge.onKey] as? Bool, on != isMacFullscreen
        else { return }
        isMacFullscreen = on
        Self.outlineLog.info("handleWindowFullScreenChange -> \(on, privacy: .public)")
        // The zen re-assert on landing windowed (the glue restores the
        // toolbar unconditionally) rides inside the presentation pass, so
        // the bind-restore lane and the test seam get it too.
        applyMacChromePresentation()
    }

    /// Which tab UI this scene shows right now. Windowed: the AppKit strip
    /// in the titlebar (UIKit band hidden). Full screen: the UIKit band (system
    /// toolbar hidden by the glue).
    ///
    /// Zen hides both. Without the glue the UIKit band is the only tab UI and
    /// its visibility belongs to the zen path alone.
    private func applyMacChromePresentation() {
        guard SceneDelegate.isAppKitGlueAvailable else { return }
        setBandHidden(!(isMacFullscreen && !isZen), fadeOver: pendingZenBandFade)
        // Before the auto-hide re-write below, which slides the band by the
        // height this pass just decided.
        applyBandLayout()
        // Ownership of the tab row just moved between the UIKit band and the
        // AppKit strip; re-write the auto-hide state to both so the chrome
        // that just lost it does not carry a stale transform (or fade) into
        // its next turn. Unanimated: the window is mid-transition.
        applyChromeAutoHideState(animated: false)
        // Landing windowed while zen must re-quiet the strip: the glue restores
        // the toolbar on full-screen exit unconditionally. This lives here, not
        // in the full-screen handler, because three lanes land windowed (the
        // notification, the bind payload's restored state, the test seam) and
        // all need it (`stripVisibilityMatchesTheState`).
        //
        // Full screen is posted too: the glue hides the strip on its own, but
        // the app's recorded decision must say so, or a later auto-hide `faded:
        // false` post brings the strip back.
        //
        // `MacStripExpectation.forState` is the rule, and the same oracle the
        // invariant checks this decision against, so asking it keeps the two
        // from drifting.
        let strip = MacStripExpectation.forState(
            window: isMacFullscreen ? .fullscreen : .windowed,
            // Visibility does not read `sidebar` — only the chip inset does,
            // and that is pushed by `pushStripLeadingInset`.
            sidebar: .hidden,
            mode: isZen ? .zen : .normal,
            glueAvailable: true, // guarded at the top of this method
            dividerX: 0)
        if macStrip.lastVisible != strip.visible { macStrip.postVisibility(strip.visible) }
    }

    /// The divider the chips inset to, and the column the paint is cut around,
    /// both read off the live split view. A compact or collapsed window has
    /// no tiled Library to inset past. The arithmetic is `BandLayout.resolve`'s.
    ///
    /// The divider is `liveDivider(of:)`: macOS 27 Catalyst keeps the column
    /// frame full-size and carves the Library out of the safe area, where the
    /// bare origin reads 0 with the Library open
    /// (docs/issues/2026-09-17-macos-27-breaks-the-mac-chrome.md).
    private func measuredBandInputs() -> BandInputs {
        guard displayMode != .secondaryOnly,
              traitCollection.horizontalSizeClass != .compact,
              let secondary = viewController(for: .secondary)?.viewIfLoaded else { return (0, nil) }
        let edge = liveDivider(of: secondary)
        guard edge > 1 else { return (0, nil) }
        let column = viewController(for: .primary)?.viewIfLoaded
        return (edge, (column?.bounds.width ?? 0) > 0 ? column : nil)
    }

    /// What `measuredBandInputs` reads off the live columns.
    private typealias BandInputs = (dividerX: CGFloat, libraryColumn: UIView?)

    /// The editor column's leading edge in root coordinates plus its left
    /// safe-area inset: the live divider. Older Catalyst moves the column's
    /// frame; macOS 27 keeps it full-size and carves the sidebar out of the
    /// safe area. Exactly one term is nonzero. Nothing scrolls the column's plain view (bounds origin
    /// zero), so its local zero is its frame's leading edge.
    private func liveDivider(of column: UIView) -> CGFloat {
        column.convert(CGPoint.zero, to: view).x + column.safeAreaInsets.left
    }

    /// The spec constants `BandLayout` builds the band out of. One place, so
    /// the pure function never has to guess at the tokens.
    private static let bandMetrics = BandLayout.Metrics(
        tabStripHeight: ChalkMetrics.tabStripHeight,
        tabStripLeading: ChalkMetrics.tabStripLeading,
        tabRowDividerGap: ChalkMetrics.tabRowDividerGap,
        editorRestingPad: ChalkMetrics.editorRestingPad)

    /// The band's one layout pass: measure the divider off the live columns,
    /// ask `BandLayout` for the numbers, write them. Every trigger goes through
    /// here (first layout, a safe-area change, a layout pass, a zen toggle, a
    /// presentation pass) so no two triggers write disagreeing subsets of
    /// the same picture. `measured` is passed only by a caller that already
    /// measured this pass.
    private func applyBandLayout(measured: BandInputs? = nil) {
        let measured = measured ?? measuredBandInputs()
        let layout = BandLayout.resolve(
            glueAvailable: SceneDelegate.isAppKitGlueAvailable,
            fullscreen: isMacFullscreen, zen: isZen,
            safeAreaTop: view.safeAreaInsets.top,
            lastRealBandHeight: lastRealBandHeight,
            dividerX: measured.dividerX, metrics: Self.bandMetrics)
        lastRealBandHeight = layout.recordedBandHeight

        if abs((headerHeight?.constant ?? -1) - layout.bandHeight) > 0.5 {
            headerHeight?.constant = layout.bandHeight
        }
        if layout.bandOwnsTabRow {
            // The band never moves and its cover reaches the window's leading
            // edge; the Library is cut out of that paint rather than drawn over
            // (`libraryIsNeverPaintedOver`).
            headerBar.setStripLeadingInset(layout.chipLeadingInset)
            headerBar.setLibraryHole(measured.libraryColumn.map { libraryHole(upTo: $0) })
            headerBar.setOutlineHole(outlineHole())
        }
        // Overlay chrome: the editor runs full-bleed under the band and its
        // resting offset is web-side padding, so scrolled text slides to the
        // window's top edge instead of clipping at a dead band. The
        // explicit-clearance API stays the mechanism, set to zero.
        editor.setTopClearance(layout.editorTopClearance)
        if let inset = layout.editorChromeTopInset { editor.setChromeTopInset(Double(inset)) }
    }

    /// Where the chrome that reserves space above the text ENDS, in this
    /// root's coordinates: the band's live floor while it is hosted, the
    /// system titlebar's inset while it reserves, and 0 in full screen with
    /// the band hidden by zen, where nothing reserves at all. The editor rests
    /// one line below it, and the Library starts its list on it
    /// (`libraryTreeTop`).
    private var chromeReserve: CGFloat {
        guard headerBar.isHidden else { return headerBar.frame.maxY }
        return isMacFullscreen ? 0 : view.safeAreaInsets.top
    }

    /// Where the Library's list begins, in this root's coordinates: the
    /// chrome floor. The band is the system titlebar spanning the whole
    /// window, so the Library goes below it.
    private var libraryTreeTop: CGFloat { chromeReserve }

    /// That line in the Library's own coordinates, or nil when it has no view
    /// in a window to convert into.
    ///
    /// Its own, not the window's: a window-space line goes stale when an
    /// ancestor moves without laying the Library out again, which a column
    /// slide does. Asked rather than pushed, because a push is only as fresh as
    /// its last caller.
    private func libraryTreeTopForLibrary() -> CGFloat? {
        guard let sidebarView = sidebar.viewIfLoaded, sidebarView.window != nil else { return nil }
        return sidebarView.convert(CGPoint(x: 0, y: libraryTreeTop), from: view).y
    }

    /// The outline panel's slice of the band, cut out of the cover: from the
    /// panel's leading edge to the band's trailing edge, the band's full
    /// height. Nil while the panel is hidden. Mirrors `libraryHole(upTo:)`.
    private func outlineHole() -> CGRect? {
        guard let editorView = editor.viewIfLoaded,
              let panel = editor.outlinePanelFrame else { return nil }
        let inBand = headerBar.convert(panel, from: editorView)
        return CGRect(x: inBand.minX,
                      y: headerBar.bounds.minY,
                      width: max(0, headerBar.bounds.maxX - inBand.minX),
                      height: headerBar.bounds.height)
    }

    /// The panel's width in MAC points for the AppKit strip's post; 0 hidden.
    private var outlineWidthForStrip: CGFloat {
        (editor.outlinePanelFrame?.width ?? 0) / ChalkMetrics.displayScale
    }

    /// The Library's side of the band, cut out of the cover: from the band's
    /// leading edge to the column's trailing edge, the band's full height.
    /// Square, because the panel is. The divider is the only measured input,
    /// so this is immune to the panel's own layout landing a pass later.
    private func libraryHole(upTo column: UIView) -> CGRect {
        let columnInBand = headerBar.convert(column.bounds, from: column)
        return CGRect(x: headerBar.bounds.minX,
                      y: headerBar.bounds.minY,
                      width: max(0, columnInBand.maxX - headerBar.bounds.minX),
                      height: headerBar.bounds.height)
    }

    // MARK: - Auto-hiding chrome
    //
    // iA-style: scrolling down slides the tab band and the utility pill away;
    // scrolling back up (or reaching the document top) returns them. Every
    // window mode runs the same policy; only what "hidden" means differs.
    //
    //  - Full screen: the UIKit band is the tab UI, so it slides out under a
    //    transform.
    //  - Windowed: the titlebar stays put and the AppKit chips fade. Hiding
    //    the toolbar would resize the content area on every change of scroll
    //    direction and leave the painted band behind (it lives in the titlebar,
    //    not the toolbar).
    //
    // Zen owns chrome visibility, so the policy stands down there, and
    // `Preferences.autoHideChrome` pins the chrome for readers who want it.

    /// Tab identities as of the last update, so a dirty-marker flip can be
    /// told apart from a tab opening or closing.
    private var lastTabIdentities: [UUID] = []

    private var autoHidePolicy = ChromeAutoHidePolicy()
    /// `Preferences.autoHideChrome`, cached: `applyAutoHide` runs on every
    /// scrolled frame. Refreshed by `handleAutoHidePreferenceChange`, the one
    /// lane the Settings switch reaches every window through.
    private var autoHideEnabled = Preferences.autoHideChrome
    private var isChromeAutoHidden = false
    /// The pointer is resting in the top band. Reaching for a tab with
    /// the mouse must reveal it; a reader with no scroll wheel in hand should
    /// never have to scroll up to get the chrome back.
    private var isPointerInTopBand = false

    /// Test seam: unit tests drive `editorDidScroll` directly (no live web
    /// editor) and read the resulting state, the same shape as
    /// `isHeaderHiddenForTesting`.
    var isChromeAutoHiddenForTesting: Bool { isChromeAutoHidden }

    /// The web bundle's scroll telemetry, one post per scrolled frame.
    func editorDidScroll(offset: Double) {
        applyAutoHide(scroll: autoHidePolicy.observe(offset: offset))
    }

    /// Re-run the gate after an input OTHER than scrolling changed (the
    /// preference, the pointer). Reads the policy's current answer instead of
    /// feeding it, so the accumulated run survives.
    private func reapplyAutoHide() {
        applyAutoHide(scroll: autoHidePolicy.chrome)
    }

    private func applyAutoHide(scroll: ChromeAutoHidePolicy.Chrome) {
        switch ChromeAutoHideGate.decide(
            enabled: autoHideEnabled,
            isZen: isZen,
            pointerInTopBand: isPointerInTopBand,
            scroll: scroll
        ) {
        case .unmanaged: return
        case .shown: setChromeAutoHidden(false)
        case .hidden: setChromeAutoHidden(true)
        }
    }

    /// The switch flipped in the Settings scene. Off pins the chrome back on
    /// screen immediately rather than making the reader scroll up for it.
    @objc private func handleAutoHidePreferenceChange() {
        autoHideEnabled = Preferences.autoHideChrome
        if !autoHideEnabled { autoHidePolicy = ChromeAutoHidePolicy() }
        reapplyAutoHide()
    }

    /// Force the chrome back and restart the policy from a fresh baseline —
    /// used by explicit chrome interactions (sidebar toggle, zen exit), which
    /// must always leave the user with visible controls.
    private func revealChrome() {
        autoHidePolicy = ChromeAutoHidePolicy()
        setChromeAutoHidden(false)
    }

    private func setChromeAutoHidden(_ hidden: Bool) {
        guard isChromeAutoHidden != hidden else { return }
        isChromeAutoHidden = hidden
        applyChromeAutoHideState()
    }

    /// Write the auto-hide state to every chrome, for the ownership in force
    /// right now.
    ///
    /// Called on a state change and on every ownership change (full-screen
    /// transitions, zen, the glue's presence). The non-owner is reset
    /// explicitly: otherwise a band hidden in full screen keeps its offscreen
    /// transform and alpha 0 through `isHidden`, and comes back invisible on
    /// re-entry. `ChalkKit.TabChromeOwnership` owns the rule and its tests.
    private func applyChromeAutoHideState(animated: Bool = true) {
        let hidden = isChromeAutoHidden
        let owner = TabChromeOwnership.owner(
            isMacFullScreen: isMacFullscreen,
            isZen: isZen,
            glueAvailable: SceneDelegate.isAppKitGlueAvailable)
        let applied = TabChromeOwnership.autoHideApplication(
            owner: owner, autoHidden: hidden)
        macStrip.postFaded(applied.stripFaded)
        // The utility pill is always ours, in every ownership.
        let write = {
            self.applyBandHidden(applied.bandHidden)
            self.applyPillHidden(hidden)
        }
        if animated {
            animateChrome(write)
        } else {
            UIView.performWithoutAnimation(write)
        }
    }

    private func applyBandHidden(_ hidden: Bool) {
        let shift = -(headerHeight?.constant ?? ChalkMetrics.headerHeight)
        headerBar.transform = hidden
            ? CGAffineTransform(translationX: 0, y: shift) : .identity
        headerBar.alpha = hidden ? 0 : 1
    }

    private func applyPillHidden(_ hidden: Bool) {
        // Clear the bottom edge with slack for the pill's drop shadow.
        let shift = ChalkMetrics.footerPillHeight + ChalkMetrics.footerPillMargin + 24
        footerBar.transform = hidden
            ? CGAffineTransform(translationX: 0, y: shift) : .identity
        footerBar.alpha = hidden ? 0 : 1
    }

    private func animateChrome(_ apply: @escaping () -> Void) {
        guard motionAllowed else {
            UIView.performWithoutAnimation(apply)
            return
        }
        UIView.animate(withDuration: ChromeMotion.autoHide, delay: 0,
                       options: [.beginFromCurrentState, .curveEaseOut],
                       animations: apply)
    }

    /// Pointer crossed the titlebar's edge, as tracked by the glue's band view
    /// (windowed) — AppKit owns those pixels and UIKit hover never fires there.
    @objc private func handleTitlebarPointerInBand(_ note: Notification) {
        guard macStrip.isAddressedToBoundWindow(note),
              let inside = note.userInfo?[TabStripBridge.insideKey] as? Bool,
              inside != isPointerInTopBand else { return }
        isPointerInTopBand = inside
        reapplyAutoHide()
    }

    /// Full screen: the band is UIKit, so UIKit's own hover recognizer sees
    /// the pointer and the glue lane above is silent.
    @objc private func handleChromeHover(_ recognizer: UIHoverGestureRecognizer) {
        let inside: Bool
        switch recognizer.state {
        case .began, .changed:
            let band = max(view.safeAreaInsets.top, lastRealBandHeight)
            inside = recognizer.location(in: view).y <= band
        default:
            inside = false
        }
        guard inside != isPointerInTopBand else { return }
        isPointerInTopBand = inside
        reapplyAutoHide()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        trackSidebarColumnWidth()
        // One measurement serves both the strip's divider and the band, so
        // they read the same column edge.
        let measured = measuredBandInputs()
        pushStripLeadingInset(measuredDividerX: measured.dividerX)
        // Runs every layout pass, so the chips track a live column drag. The
        // editor's view may not have existed at viewDidLoad (its top clearance
        // no-ops until loaded), and on a device with zero system insets
        // viewSafeAreaInsetsDidChange never fires — re-assert here. Guarded
        // writes inside, so steady passes are free.
        applyBandLayout(measured: measured)
    }

    /// The titlebar strip starts at the editor column's left edge while the
    /// sidebar is tiled, and slides back to the traffic lights when it hides.
    /// The strip is AppKit, so the divider goes over in Mac points. Runs every
    /// layout pass: cheap, idempotent, and window-number-gated on the receiving
    /// side. `measuredDividerX` is passed only by a caller that already
    /// measured this pass.
    private func pushStripLeadingInset(measuredDividerX: CGFloat? = nil) {
        // Never from a pass the slide owns. The hide posts its TARGET inset at
        // slide start, while the column stays tiled (so the measured divider
        // stays the old one) until the completion snaps the display mode: a
        // layout pass in between would post the old divider back, unanimated,
        // and the chips would jump back to it. Each completion pushes again.
        guard slidingSidebarColumn == nil else { return }
        #if DEBUG
        stripLeadingInsetPushCountForTesting += 1
        #endif
        // The same divider the UIKit band's chips inset to, in mac points: two
        // measurements of one column edge is how the two tab rows drifted apart.
        macStrip.postLeadingInset(
            dividerX: (measuredDividerX ?? measuredBandInputs().dividerX) / ChalkMetrics.displayScale,
            outlineWidth: outlineWidthForStrip,
            slideDuration: pendingStripSlideDuration)
    }

    /// Set around the slide-start layout pass (`animateSidebarIn`) and consumed
    /// by the divider post that pass emits: the strip must ride the slide's
    /// clock (docs/motion.md), and the show-direction post comes from the
    /// layout pass that snaps the display mode, not from the slide code itself.
    private var pendingStripSlideDuration: TimeInterval?

    #if DEBUG
    /// Divider pushes that got past the slide guard (SidebarSlideContractTests).
    private(set) var stripLeadingInsetPushCountForTesting = 0
    #endif

    /// A click the titlebar band caught over the Library panel. Routed exactly
    /// like a strip action (by `windowNumber`, key gate only for an unbound
    /// window) and converted back from MAC points — the inverse of the divider
    /// X this scene pushes out in `pushStripLeadingInset`.
    @objc private func handleTitlebarBandClick(_ note: Notification) {
        guard macStrip.shouldHandle(note),
            let x = note.userInfo?[TabStripBridge.xKey] as? CGFloat,
            let y = note.userInfo?[TabStripBridge.yKey] as? CGFloat
        else { return }
        sidebar.replayTitlebarBandClick(atWindowPoint: CGPoint(
            x: x * ChalkMetrics.displayScale, y: y * ChalkMetrics.displayScale))
    }

    /// A middle click anywhere in the window. Only the full-screen strip acts
    /// on it — windowed, the AppKit chips close themselves — so a hidden or
    /// faded-out band ignores it, as does a point on no chip. Routed and
    /// converted exactly like the titlebar band's clicks.
    @objc private func handleGlueMiddleClick(_ note: Notification) {
        guard macStrip.shouldHandle(note),
            !headerBar.isHidden, headerBar.alpha > 0,
            let x = note.userInfo?[TabStripBridge.xKey] as? CGFloat,
            let y = note.userInfo?[TabStripBridge.yKey] as? CGFloat
        else { return }
        headerBar.tabStrip.replayMiddleClick(atWindowPoint: CGPoint(
            x: x * ChalkMetrics.displayScale, y: y * ChalkMetrics.displayScale))
    }

    /// True while the hand-rolled slide owns the column (see the testing seam
    /// of the same name).
    private var isSidebarTransitionInFlight: Bool {
        slidingSidebarColumn != nil || sidebarSlideSettle?.isActive == true
    }

    /// Persist the live Library column width as the last-used value. Runs on
    /// every layout pass, so it must be cheap and idempotent: it writes
    /// `Preferences` only when the value actually changed.
    private func trackSidebarColumnWidth() {
        let compact = traitCollection.horizontalSizeClass == .compact
        guard !compact, displayMode != .secondaryOnly,
              let secondary = viewController(for: .secondary)?.viewIfLoaded
        else { return }
        // Never from a layout pass the slide owns: a column mid-flight reports
        // an edge on its way somewhere, and persisting it drifts the Library's
        // width on every toggle. A drag happens at rest, so waiting for rest
        // costs it nothing.
        guard !isSidebarTransitionInFlight else { return }
        // What the preference means: the width the split view gave the primary
        // column, minus its own leading safe area (Catalyst parks a ~100pt
        // offscreen overhang there), so applying a width and reading it back is
        // a fixed point. The secondary column's leading edge adds the
        // 1.5pt inter-column gutter and grows the
        // Library on every pass; it is only the fallback when there is no
        // primary view to measure.
        let edge: CGFloat
        if let primary = viewController(for: .primary)?.viewIfLoaded, primary.bounds.width > 1 {
            edge = primary.bounds.width - primary.safeAreaInsets.left
        } else {
            edge = max(secondary.convert(CGPoint.zero, to: view).x,
                       secondary.safeAreaInsets.left)
        }
        guard edge > 1 else { return }
        // Persist within the resizable bounds and only on a real change, so a
        // steady layout pass never churns UserDefaults. 2.0 is a rounding
        // guard; a real drag moves many points.
        if Preferences.sidebarWidthRange.contains(edge),
           abs(Preferences.sidebarWidth - edge) > 2.0 {
            Preferences.sidebarWidth = edge
        }
    }

    /// Flush every open tab (scene background / resign-active) so no edit is
    /// lost. `completion` fires once every write callback has landed, so the
    /// scene delegate can hold a background-task assertion open until then.
    func saveAllDocuments(completion: (() -> Void)? = nil) {
        editor.saveAll(completion: completion)
    }

    /// Crash net: write recovery snapshots of every dirty buffer right now
    /// (drafts included — saveAll skips those). Synchronous small writes.
    func snapshotDirtyBuffers() {
        editor.snapshotDirtyBuffers()
    }

    /// Reopen buffers a crash/force-quit left behind. Each scene connect
    /// claims its own tabs' records (`matchingOwnTabsOnly: true`); the
    /// once-per-process leftover drain passes `false` (see SceneDelegate).
    func restoreRecoveredBuffers(matchingOwnTabsOnly: Bool = false) {
        editor.restoreRecoveredBuffers(matchingOwnTabsOnly: matchingOwnTabsOnly)
    }

    /// On foreground, re-read externally-changed files and refresh the Library.
    func reloadExternalChanges() {
        editor.reloadExternalChanges()
        // Foreground refresh can hit a cold iCloud Location: off-main.
        sidebar.scheduleReload()
    }

    /// One log line describing what this window is actually showing.
    /// SceneDelegate prints it on every connect / foreground / activate, so an
    /// empty window names its mechanism in the device log
    /// (docs/issues/2026-08-18-window-comes-up-empty-after-switching.md).
    var stateSummary: String {
        let mode: String
        switch displayMode {
        case .secondaryOnly: mode = "secondaryOnly"
        case .oneBesideSecondary: mode = "oneBesideSecondary"
        case .oneOverSecondary: mode = "oneOverSecondary"
        case .twoBesideSecondary: mode = "twoBesideSecondary"
        default: mode = "other(\(displayMode.rawValue))"
        }
        return "tabs=\(editor.openTabCount) \(editor.diagnosticSummary)"
            + " \(sidebar.diagnosticSummary) displayMode=\(mode)"
            + " band=\(Int(headerHeight?.constant ?? -1))"
            + " safeTop=\(Int(view.safeAreaInsets.top))"
            + " size=\(Int(view.bounds.width))x\(Int(view.bounds.height))"
    }

    /// Security-scoped access claimed for files opened from Finder. Held for the window's lifetime so the sandbox extension outlives
    /// the open tab, then released when the scene disconnects
    /// (`releaseExternalScopes`, called from SceneDelegate) with a deinit
    /// backstop.
    private var externalScopedURLs: [URL] = []

    /// Scene teardown: give the claimed sandbox extensions back. Idempotent —
    /// disconnect and deinit can both call it.
    func releaseExternalScopes() {
        for url in externalScopedURLs { url.stopAccessingSecurityScopedResource() }
        externalScopedURLs.removeAll()
        locationStore.releaseScopes()
    }

    deinit {
        releaseExternalScopes()
    }

    /// This window's folders that currently grant access, as Quick Open, figure lookup and
    /// `ExternalOpenRouter` see them.
    var libraryRoots: [URL] {
        locationStore.locations().filter { !$0.needsReauthorization }.map(\.url)
    }

    /// No tabs and no folders: an external folder open fills this window instead of opening another.
    var isPristine: Bool { editor.openTabCount == 0 && locationStore.locations().isEmpty }

    /// Add `url` to this window's folders and show the Library. False when it could not be stored
    /// (the user has been told).
    @discardableResult
    func addFolderToWindow(_ url: URL) -> Bool {
        guard locationStore.add(url: url) else {
            sidebar.showFileOpFailure(
                "Couldn\u{2019}t add \u{201C}\(url.lastPathComponent)\u{201D} to this window. Try adding the folder again.")
            return false
        }
        setSidebarVisible(true)
        return true
    }

    /// Open a document handed to us by the OS (Finder double-click, "Open
    /// With"). Routed here by `ExternalOpenRouter`, and by the sidebar's Open in New Window.
    func openExternalDocument(_ url: URL) {
        if url.startAccessingSecurityScopedResource() {
            externalScopedURLs.append(url)
        }
        // Reveal the editor column (a launch may land on the sidebar in compact
        // width) and open the file, reusing a clean tab like a sidebar click.
        show(.secondary)
        editor.open(url: url, reuseCurrentIfClean: true)
    }

    // MARK: - Scene restoration

    /// Tab count drafts included, for the launch-settle ghost sweep: a window
    /// is disposable at launch only when it holds nothing at all.
    var openTabCount: Int { editor.openTabCount }

    /// Snapshot this window's restorable state (open file tabs, active tab,
    /// sidebar visibility) for `SceneDelegate.stateRestorationActivity`.
    /// Always non-nil (an empty window restores empty): with no stored
    /// activity the reconnect path falls back to `.welcome`, which would turn
    /// an emptied window into a second Welcome on every relaunch.
    func captureRestorationActivity() -> NSUserActivity? {
        let snapshot = editor.sessionSnapshot()
        let sidebarVisible = displayMode != .secondaryOnly
        let records = snapshot.urls.map {
            // A bookmark per tab, not just for Finder-opened files: it makes
            // restoration independent of Location-resolution order, and it is
            // the only thing that reopens an external file's sandbox scope
            // after relaunch (the live scope dies with the process).
            WindowSession.TabRecord(path: $0.path, bookmark: FileBookmark.make(for: $0))
        }
        let session = WindowSession(
            tabs: records, activeIndex: snapshot.activeIndex,
            isSidebarVisible: sidebarVisible,
            isOutlineVisible: editor.isOutlinePanelVisible)
        guard let data = session.encoded() else { return nil }
        let activity = NSUserActivity(activityType: ChalkActivity.windowType)
        activity.userInfo = [ChalkActivity.stateKey: data]
        return activity
    }

    /// Reopen a restored window's tabs. Unresolvable or unreadable files (moved
    /// or deleted between quit and relaunch) are dropped silently.
    private func applyRestoredSession(_ session: WindowSession) {
        var openedRecordIndices: [Int] = []
        for (index, record) in session.tabs.enumerated() {
            let url = record.bookmark.flatMap(FileBookmark.resolve)
                ?? URL(fileURLWithPath: record.path)
            // Enter the scope before the readability check — outside it, a
            // sandboxed file isn't readable at all. Held for the session,
            // exactly like a Finder-opened file (see externalScopedURLs).
            let accessing = url.startAccessingSecurityScopedResource()
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                if accessing { url.stopAccessingSecurityScopedResource() }
                continue
            }
            if accessing { externalScopedURLs.append(url) }
            // activating: false: bulk restore must not boot one webview per tab
            // (a file-descriptor storm); only the final activate below boots
            // one.
            editor.open(url: url, activating: false)
            openedRecordIndices.append(index)
        }
        // The snapshot's activeIndex counts encoded tabs; map it through the
        // ones that actually reopened. If the active one was dropped, fall
        // back to the first opened tab — with `activating: false` above,
        // nothing is active until this runs.
        if let wanted = session.activeIndex,
           let position = openedRecordIndices.firstIndex(of: wanted) {
            editor.activateTab(at: position)
        } else if !openedRecordIndices.isEmpty {
            editor.activateTab(at: 0)
        }
        if session.isSidebarVisible {
            preferredDisplayMode = .oneBesideSecondary
        }
        if session.isOutlineVisible {
            editor.setOutlinePanelVisible(true, animated: false)
        }
    }

    // MARK: - Shell commands
    // Surfaced as the menu bar via AppDelegate.buildMenu(with:); they route
    // here through the responder chain.

    /// One key press can invoke a shell command twice: the Catalyst menu key
    /// equivalent and the webview's `pressesBegan` fallback
    /// (WebEditorSurface.shellAction) both fire, and share no UIEvent to dedupe
    /// on. So coalesce at the selector: a ghost duplicate arrives in the same
    /// event turn (well under 50 ms), deliberate repeats are ≥ ~100 ms apart,
    /// and the default 0.1 s window drops only the ghost. The palette toggles
    /// use 0.3 s: an intentional re-toggle is always slower than that.
    private func admitShellAction(_ selector: Selector, window: CFTimeInterval = 0.1) -> Bool {
        let now = CACurrentMediaTime()
        if let last = lastShellDispatch[selector], now - last < window { return false }
        lastShellDispatch[selector] = now
        return true
    }

    /// Shell commands that must act on the window the user is actually in.
    /// Mirrors AppDelegate.buildMenu (every cmd* routed at this class).
    private static let shellSelectors: Set<Selector> = [
        #selector(cmdSave), #selector(cmdNewFile), #selector(cmdCloseTab),
        #selector(cmdQuickOpen), #selector(cmdToggleOutline), #selector(cmdToggleOutlinePanel),
        #selector(cmdAddLocation),
        #selector(cmdToggleSidebar), #selector(cmdSettings),
        #selector(cmdReportProblem), #selector(cmdPrivacy),
        #selector(cmdZoomIn), #selector(cmdZoomOut), #selector(cmdZoomReset),
        #selector(cmdNextTab), #selector(cmdPrevTab),
        #selector(cmdCycleEditingMode), #selector(cmdEditingModeNormal),
        #selector(cmdEditingModeZen), #selector(cmdEditingModeTypewriter),
        #selector(cmdEditingModeFocus),
        #selector(cmdViewModePreview), #selector(cmdViewModeMixed),
        #selector(cmdViewModeSource),
    ]

    /// The menu bar's shell UIKeyCommands have a nil target, so UIKit resolves
    /// them through its app-global first responder / key window, which goes
    /// stale after a multi-window restore (every connecting scene calls
    /// makeKeyAndVisible; full-screen transitions add transient key windows).
    /// Resolution starting in the wrong scene ran Cmd+S on the other window.
    ///
    /// So every instance re-routes shell actions by identity: to the scene
    /// bound to the AppKit key window (`appKitKeyWindowNumber`; AppKit is the
    /// authority), else to the scene whose UIWindow reports key, else
    /// locally. At most one of each exists, so the redirect terminates (the
    /// chosen scene resolves to itself).
    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if Self.shellSelectors.contains(action),
           let redirect = shellRedirectTarget(), redirect !== self {
            return redirect.target(forAction: action, withSender: sender)
        }
        return super.target(forAction: action, withSender: sender)
    }

    /// The scene shell actions should run on, or nil to handle locally.
    private func shellRedirectTarget() -> RootSplitViewController? {
        let candidates = Self.everyLiveRoot()
        guard candidates.count > 1 else { return nil }
        let appKitKey = MacStripBridge.appKitKeyWindowNumber
        let bound = candidates.map { candidate in
            appKitKey != nil && candidate.macStrip.boundNumber == appKitKey
        }
        guard let index = WindowRouting.shellTargetIndex(
            boundToActiveWindow: bound,
            uikitKey: candidates.map { $0.viewIfLoaded?.window?.isKeyWindow == true })
        else { return nil }
        return candidates[index]
    }

    /// Apply the stored editor font scale to this window's tabs.
    func applyEditorFontScale() { editor.setFontScale(Preferences.editorFontScale) }

    /// Apply the stored text column width to this window's tabs.
    func applyEditorMeasure() { editor.setMeasure(Preferences.editorMeasure) }

    /// Apply the stored interline spacing to this window's tabs.
    func applyEditorLineHeight() { editor.setLineHeight(Preferences.editorLineHeight) }

    /// Apply the stored wrapped-prose alignment to this window's tabs.
    func applyTextAlignment() { editor.setTextAlign(Preferences.textAlignment) }

    /// Push the shell-owned editor config (editing mode, default view mode) to
    /// this window's tabs. The container reads this window's own `editingMode`
    /// through the closure wired in `init`, never the global
    /// `Preferences.editingMode`.
    func applyEditorConfig() { editor.applyEditorConfig() }

    /// Change the DEFAULT view mode: persist it and push it to every tab of
    /// every window (it is one process-wide preference, which new tabs in any
    /// window read). A tab the user cycled with Cmd+: follows only when the
    /// default itself changes (editor-core's reset rule).
    func setViewModeDefault(_ mode: ViewMode) {
        Preferences.viewMode = mode
        for root in liveRootsIncludingSelf() { root.applyEditorConfig() }
    }

    @objc func cmdViewModePreview() { setViewModeDefault(.preview) }
    @objc func cmdViewModeMixed() { setViewModeDefault(.mixed) }
    @objc func cmdViewModeSource() { setViewModeDefault(.source) }

    /// Push the heading palette (or the empty payload that clears it) to this
    /// window's tabs.
    func applyHeadingColors() { editor.applyHeadingColors() }

    /// Push already-composed hsnips to this window's tabs.
    func pushHsnips(_ content: String) { editor.setHsnips(content) }

    /// `everyLiveRoot()`, plus this root when it is not in a window scene
    /// yet: the window a change came from always applies it.
    private func liveRootsIncludingSelf() -> [RootSplitViewController] {
        let roots = Self.everyLiveRoot()
        return roots.contains { $0 === self } ? roots : roots + [self]
    }

    /// Every live window's root controller, across all connected scenes: for
    /// process-wide settings that must reach more than the window they were
    /// changed from, and for shell-command routing.
    static func everyLiveRoot() -> [RootSplitViewController] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .compactMap { $0.rootViewController as? RootSplitViewController }
    }

    /// Run a sidebar display-mode change with a short slide; Reduce Motion
    /// snaps instantly.
    ///
    /// The editor is a WKWebView, which paints asynchronously in the
    /// web-content process, so any bounds change near the animation flashes
    /// stale tiles at the wrong layout. The visible slide therefore never
    /// touches the webview's bounds: the width is frozen at its current value
    /// and the content is translated instead (`contentShift`). The one real
    /// reflow runs after the slide, while everything is stationary, under a
    /// `takeSnapshot` image of the settled content (`settleSidebarSlide`).
    /// Never `snapshotView(afterScreenUpdates:)`: over a webview's remote layer
    /// it can come back empty.
    private func animateSidebar(show: Bool) {
        // Zen owns the chrome: panels do not open into it, whichever lane
        // asked (Cmd+J, the pill, a test step). The way out is
        // leaving zen. `UIState.applying` encodes the same refusal, so the
        // transition oracle and the shell agree.
        if show, isZen { return }
        let change = { self.setSidebarVisible(show) }
        guard motionAllowed else {
            UIView.performWithoutAnimation { change(); view.layoutIfNeeded() }
            return
        }
        // One code path (docs/motion.md "Sidebar show/hide"): a dead
        // snapshotter degrades to a covered reflow on the
        // backstop clock (WebPaintGate), never a stuck width. A rapid re-toggle
        // lands mid-slide: finish the previous transition's bookkeeping before
        // starting over.
        cancelSidebarSlide()
        if show { animateSidebarIn() } else { animateSidebarOut() }
    }

    /// Hide through the display-mode preference, never
    /// `hide(.primary)`: that leaves the secondary column re-tiled 1.5pt right
    /// (its divider gutter) with its trailing edge off-window, a metastable
    /// state a later system pass may or may not fix, on a clock no app layout
    /// pass sees (`editorContentFillsTheColumn`).
    private func hideSidebarColumn() {
        preferredDisplayMode = .secondaryOnly
    }

    /// Reveal/hide the Library column.
    private func setSidebarVisible(_ visible: Bool) {
        if visible { show(.primary) } else { hideSidebarColumn() }
    }

    /// `show(.primary)` runs the split view's own column animation on its own
    /// clock, which content driven by our block cannot follow, and our
    /// completion fires while the column is still moving. So the display-mode
    /// change is applied instantly and the slide is ours, on one clock: the
    /// column starts transform-shifted offscreen and slides in while the frozen
    /// editor content slides by `contentShift`.
    private func animateSidebarIn() {
        editor.freezeContentWidth()
        // The display-mode snap at slide start. The layout
        // pass inside also posts the new divider to the AppKit strip, so the
        // chips move on the column's clock.
        pendingStripSlideDuration = ChalkMetrics.motionSidebar
        UIView.performWithoutAnimation {
            setSidebarVisible(true)
            view.layoutIfNeeded()
        }
        pendingStripSlideDuration = nil
        guard let editorView = editor.viewIfLoaded,
              let sidebarColumn = sidebarColumnContainer() else {
            settleSidebarSlide()
            return
        }
        // The live divider, post-snap: the truth, not the preference.
        let sidebarWidth = liveDivider(of: editorView)
        let shift = contentShift(sidebarWidth: sidebarWidth, showing: true)
        // The frozen full-width content overhangs the (now narrower) column's
        // leading edge; it must stay visible there until the sidebar covers it.
        editorView.clipsToBounds = false
        // The sidebar slides in ON TOP of that overhang. Keep app chrome above.
        liftSidebarColumn(sidebarColumn)
        sidebarColumn.transform = CGAffineTransform(translationX: -sidebarWidth, y: 0)
        slidingSidebarColumn = sidebarColumn

        UIView.animate(withDuration: ChalkMetrics.motionSidebar,
                       delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState]) {
            sidebarColumn.transform = .identity
            self.editor.slideContent(by: shift)
        } completion: { [epoch = sidebarSlideEpoch] _ in
            // A re-toggle canceled this slide; its bookkeeping is done and
            // running the settle here would unfreeze mid-NEW-slide.
            guard epoch == self.sidebarSlideEpoch else { return }
            self.slidingSidebarColumn = nil
            editorView.clipsToBounds = true
            self.pushStripLeadingInset() // anything the slide guard held back
            self.settleSidebarSlide()
        }
    }

    /// How far the visible text travels when the editor column resizes by one
    /// sidebar width. The web content column is `Preferences.editorMeasure`
    /// wide (the CSS px the host pushes into the page), centered while the
    /// editor is wider than that and edge-anchored below the cap. So the travel
    /// is the leading-edge move plus the inset change: Δ/2 when fully wide, the
    /// full sidebar width when fully narrow, in between when the toggle crosses
    /// the cap.
    private func contentShift(sidebarWidth: CGFloat, showing: Bool) -> CGFloat {
        let measure = CGFloat(Preferences.editorMeasure)
        func inset(_ editorWidth: CGFloat) -> CGFloat {
            max(0, (editorWidth - measure) / 2)
        }
        let wide = view.bounds.width          // editor width, sidebar hidden
        let narrow = wide - sidebarWidth      // editor width, sidebar shown
        let travel = sidebarWidth + inset(narrow) - inset(wide)
        return showing ? travel : -travel
    }

    /// Mirror of `animateSidebarIn`, with the display-mode change at the END:
    /// `hide(.primary)` unhosts the column view, so the real view slides out
    /// first and the hide is snapped in the completion — the frozen content's
    /// screen rect is identical across that snap, making it invisible.
    private func animateSidebarOut() {
        guard let editorView = editor.viewIfLoaded,
              let sidebarColumn = sidebarColumnContainer(),
              displayMode != .secondaryOnly else {
            UIView.performWithoutAnimation { hideSidebarColumn(); view.layoutIfNeeded() }
            return
        }
        let sidebarWidth = liveDivider(of: editorView)
        let shift = contentShift(sidebarWidth: sidebarWidth, showing: false)
        editor.freezeContentWidth()
        // The chips ride the column's clock (docs/motion.md): the hide's
        // display-mode change lands only in the completion, so post the target
        // inset now. The completion's layout pass recomputes the same 0 and the
        // dedupe stays silent.
        macStrip.postLeadingInset(dividerX: 0, outlineWidth: outlineWidthForStrip,
                                  slideDuration: ChalkMetrics.motionSidebar)
        // The content's visual rect crosses the column's leading edge on its
        // way out; the departing sidebar (kept above) covers the seam.
        editorView.clipsToBounds = false
        liftSidebarColumn(sidebarColumn)
        slidingSidebarColumn = sidebarColumn

        UIView.animate(withDuration: ChalkMetrics.motionSidebar,
                       delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState]) {
            sidebarColumn.transform = CGAffineTransform(translationX: -sidebarWidth, y: 0)
            self.editor.slideContent(by: shift)
        } completion: { [epoch = sidebarSlideEpoch] _ in
            guard epoch == self.sidebarSlideEpoch else { return }
            self.slidingSidebarColumn = nil
            editorView.clipsToBounds = true
            UIView.performWithoutAnimation {
                self.hideSidebarColumn()
                sidebarColumn.transform = .identity
                self.view.layoutIfNeeded()
            }
            self.pushStripLeadingInset() // after the snap: the divider is final
            self.settleSidebarSlide()
        }
    }

    /// The split-view subtree that hosts the Library column and nothing else:
    /// the primary controller's view walked up until the next parent would also
    /// host the editor, so the slide transform moves the whole column and only
    /// the column.
    ///
    /// The editor test is load-bearing: where both columns share one
    /// `_UISplitViewControllerAdaptiveColumnContainerView` (the split view
    /// macOS 27 Catalyst tiles with), climbing to it slides the editor off
    /// screen on the hide too. The transition suites run
    /// the instant lane, so only the animated hide shows it.
    private func sidebarColumnContainer() -> UIView? {
        guard let primaryView = viewController(for: .primary)?.view else { return nil }
        let editorView = editor.viewIfLoaded
        var candidate = primaryView
        while let parent = candidate.superview, parent !== view {
            if let editorView, editorView.isDescendant(of: parent) { break }
            candidate = parent
        }
        return candidate
    }

    /// Raise the Library column so it covers the editor's frozen overhang for
    /// the duration of the slide.
    ///
    /// Reparenting is only correct when the column is already a direct child
    /// of the split view's view (older Catalyst). Where the
    /// columns share a private container, `insertSubview` would lift the
    /// Library out of the container the split view lays it out in and never
    /// put it back, so the stacking is done inside that container instead.
    private func liftSidebarColumn(_ column: UIView) {
        if column.superview === view {
            view.insertSubview(column, belowSubview: headerBar)
        } else {
            column.superview?.bringSubviewToFront(column)
        }
    }

    /// Abort any in-flight slide so a new one starts from consistent state.
    /// The epoch bump turns the canceled animation's completion into a no-op
    /// and `cancel()` does the same for the settle's pending callbacks — a
    /// stale snapshot or backstop must never act on the next slide's state.
    private func cancelSidebarSlide() {
        sidebarSlideEpoch += 1
        sidebarSlideSettle?.cancel()
        sidebarSlideSettle = nil
        slidingSidebarColumn?.layer.removeAllAnimations()
        slidingSidebarColumn?.transform = .identity
        slidingSidebarColumn = nil
        editor.viewIfLoaded?.clipsToBounds = true
        editor.unfreezeContentWidth()
    }

    /// Post-slide settle: swap the frozen, translated webview for its real
    /// layout in one stationary reflow, masked by an opaque cover carrying a
    /// bitmap of the pixels on screen. `WebPaintGate` owns the ordering and the
    /// guaranteed release (docs/motion.md "Sidebar show/hide"): the release is
    /// armed before the snapshot is requested, so a snapshot that never lands
    /// degrades to a covered reflow on the backstop clock, never a stuck width
    /// or a naked reflow. The shield is `makeWebCover`.
    private func settleSidebarSlide() {
        guard let editorView = editor.viewIfLoaded else {
            editor.unfreezeContentWidth()
            return
        }
        guard let seams = coverSeams(for: .sidebarSlide) else {
            // No webview to mask (no open tab): nothing can flicker — release
            // immediately.
            editor.unfreezeContentWidth()
            return
        }
        let settle = WebPaintGate(
            snapshotter: seams.snapshotter,
            paintGate: seams.paintGate,
            makeCover: { [weak self] image in
                self?.makeWebCover(over: editorView, bitmap: image, of: seams.bitmapSource)
            },
            reflow: { [weak self] in self?.editor.unfreezeContentWidth() })
        sidebarSlideSettle = settle
        settle.begin()
    }

    /// Which covered transition is asking for seams, so a DEBUG build can
    /// hand back that transition's injected test doubles.
    private enum CoveredTransition { case sidebarSlide, appearance }

    /// The seams a covered transition runs on: the live surface's
    /// (`liveWebPaintSeams`), replaced in DEBUG by the transition's injected
    /// snapshotter and paint gate when a contract test set one (no bitmap
    /// source then). nil when there is nothing to mask.
    private func coverSeams(for transition: CoveredTransition)
        -> (snapshotter: WebPaintGate.Snapshotter,
            paintGate: WebPaintGate.PaintGate,
            bitmapSource: UIView?)? {
        let live = liveWebPaintSeams()
        #if DEBUG
        let injected: (WebPaintGate.Snapshotter?, WebPaintGate.PaintGate?)
        switch transition {
        case .sidebarSlide: injected = (sidebarSnapshotterForTesting, sidebarPaintGateForTesting)
        case .appearance: injected = (appearanceSnapshotterForTesting, appearancePaintGateForTesting)
        }
        if let snapshotter = injected.0 {
            return (snapshotter,
                    injected.1 ?? { ready in DispatchQueue.main.async(execute: ready) },
                    nil)
        }
        #endif
        return live.map { ($0.snapshotter, $0.paintGate, $0.bitmapSource) }
    }

    /// The live editor surface's covered-transition seams: a bitmap of the
    /// pixels on screen, and a gate that answers once the web process has
    /// painted the new layout. nil when there is no hosted webview to mask.
    ///
    /// The gate is two rAFs, not a delay: a fixed-delay fade races the async
    /// repaint and loses on heavy documents (KaTeX), ghosting stale tiles
    /// through the half-faded cover. Two rAFs guarantee at least one committed
    /// paint; the gate's backstop covers a stall.
    private func liveWebPaintSeams() -> (snapshotter: WebPaintGate.Snapshotter,
                                         paintGate: WebPaintGate.PaintGate,
                                         bitmapSource: UIView)? {
        guard let webView = editor.activeSurfaceWebView, webView.window != nil else { return nil }
        return (
            { done in webView.takeSnapshot(with: nil) { image, _ in done(image) } },
            { ready in
                webView.callAsyncJavaScript(
                    "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))",
                    in: nil, in: .page
                ) { _ in ready() }
            },
            webView)
    }

    /// The opaque shield both covered transitions install over the editor
    /// (docs/motion.md): the sidebar settle's reflow and the appearance flip
    /// run under it, and it outlives them until the page reports a paint.
    ///
    /// While WebKit repaints, the compositor shows the old tiles anchored to
    /// the layer's leading edge (up to half a sidebar-width off on a hide), so
    /// the shield spans the webview's entire final rect in the editor
    /// background, with the bitmap at the old visual offset. The colour is
    /// dynamic so it re-resolves when a trait flips beneath it. Never
    /// `snapshotView(afterScreenUpdates:)` (see `animateSidebar`).
    private func makeWebCover(over editorView: UIView,
                              bitmap image: UIImage?, of bitmapSource: UIView?) -> UIView? {
        guard editorView.window != nil else { return nil }
        let cover = UIView()
        cover.backgroundColor = .chalkEditorBackground
        cover.clipsToBounds = true
        // The cover masks pixels and must never gate input: it outlives the
        // covered turn until the page paints (or `paintBackstop`, 0.6s), and a
        // click landing on it would do nothing.
        cover.isUserInteractionEnabled = false
        // The webview's top is the host-set clearance, NOT the safe area: the
        // two diverge under the full-bleed titlebar, and a cover cut at the
        // safe area leaves the top band of stale tiles unshielded.
        var finalRect = editorView.bounds
        finalRect.origin.y = editor.topClearance
        finalRect.size.height -= editor.topClearance
        cover.frame = finalRect
        if let image, let bitmapSource {
            let bitmap = UIImageView(image: image)
            bitmap.frame = editorView
                .convert(bitmapSource.bounds, from: bitmapSource)
                .offsetBy(dx: -finalRect.origin.x, dy: -finalRect.origin.y)
            cover.addSubview(bitmap)
        }
        editorView.addSubview(cover)
        return cover
    }

    @objc func cmdToggleSidebar() {
        guard admitShellAction(#selector(cmdToggleSidebar)) else { return }
        // An explicit chrome interaction always brings the chrome back.
        revealChrome()
        animateSidebar(show: displayMode == .secondaryOnly)
    }

    @objc func cmdQuickOpen() {
        guard admitShellAction(#selector(cmdQuickOpen), window: 0.3) else { return }
        // Toggle: a second press closes the palette (and returns editor focus).
        if quickOpenHost.isVisible {
            hideQuickOpen { [weak self] in self?.returnFocusAfterDismiss() }
        } else {
            presentQuickOpen()
        }
    }
    /// ⌘P (outline) claimed at the scene level, for the no-glue fallback.
    ///
    /// While a native text field is editing, Catalyst hands the raw keyDown to
    /// NSTextInputContext before any UIKit mechanism, so this never fires
    /// there. The glue's AppKit event monitor covers that case and swallows
    /// ⌘P, so with the glue this is never consulted.
    /// `admitShellAction`'s 0.3s window dedupes overlap with the webview lanes.
    /// It lives here, not on the palette VCs: those are permanently mounted, so
    /// their `keyCommands` stay live while hidden and shadow the shell
    /// (docs/issues/2026-08-17-fullscreen-drops-when-outline-opens.md).
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + outlineKeyCommands
    }

    /// Built once: UIKit queries `keyCommands` on every key event.
    private lazy var outlineKeyCommands: [UIKeyCommand] = {
        let toggle = UIKeyCommand(title: "Outline",
                                  action: #selector(cmdToggleOutline),
                                  input: "p", modifierFlags: .command)
        toggle.wantsPriorityOverSystemBehavior = true
        let panel = UIKeyCommand(title: "Outline Panel",
                                 action: #selector(cmdToggleOutlinePanel),
                                 input: "k", modifierFlags: .command)
        panel.wantsPriorityOverSystemBehavior = true
        return [toggle, panel]
    }()

    @objc func cmdToggleOutline() {
        // Same wide window as Quick Open: toggle semantics, and one press can
        // arrive over three paths (menu, pressesBegan, JS forward).
        guard admitShellAction(#selector(cmdToggleOutline), window: 0.3) else { return }
        Self.outlineLog.info("cmdToggleOutline: visible=\(self.outlineHost.isVisible, privacy: .public)")
        if outlineHost.isVisible {
            hideOutlinePalette { [weak self] in self?.returnFocusAfterDismiss() }
        } else {
            presentOutlinePalette()
        }
    }

    /// ⌘K: the persistent outline panel. Same wide dedupe window as ⌘P (one
    /// press arrives over menu, pressesBegan and the JS forward). Zen owns
    /// the chrome: opening into it is refused, like the Library.
    @objc func cmdToggleOutlinePanel() {
        guard admitShellAction(#selector(cmdToggleOutlinePanel), window: 0.3) else { return }
        let show = !editor.isOutlinePanelVisible
        if show, isZen { return }
        revealChrome()
        editor.setOutlinePanelVisible(show, animated: motionAllowed)
    }

    /// The session the crash prompt and the Help screens read. Overridable so
    /// NoticeBannerTests can drive a crashed launch without touching the real
    /// preferences.
    var alphaSessionForTesting: AlphaSession?
    private var alpha: AlphaSession { alphaSessionForTesting ?? .shared }

    // MARK: - The crash prompt

    private weak var noticeBanner: NoticeBannerView?

    /// Called once the window is on screen and settled. Shows the crash
    /// prompt when the last session ended abnormally.
    func presentAlphaNoticeIfNeeded() {
        guard noticeBanner == nil else { return }
        #if DEBUG
        // The screenshot harness SIGTERMs every state it captures, so every
        // later launch reports an unclean shutdown and would paint the banner
        // over the shot.
        if AuditMode.requestedState != nil { return }
        #endif

        if alpha.claimCrashPrompt() {
            showBanner(
                message: "Chalk didn\u{2019}t shut down cleanly last time.",
                primaryTitle: "Send a report",
                onPrimary: { [weak self] in
                    self?.alpha.recordCrashPromptOutcome(.sent)
                    self?.cmdReportProblem()
                },
                onDecline: { [weak self] in
                    self?.alpha.recordCrashPromptOutcome(.declined)
                })
        }
    }

    private func showBanner(message: String,
                            primaryTitle: String?,
                            onPrimary: @escaping () -> Void,
                            onDecline: @escaping () -> Void) {
        let banner = NoticeBannerView(
            message: message,
            primaryTitle: primaryTitle,
            declineTitle: primaryTitle == nil ? "OK" : "No thanks",
            onPrimary: onPrimary,
            onDecline: onDecline)
        banner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            banner.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                           constant: -ChalkMetrics.s(56)),
            banner.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor,
                                          multiplier: 0.8),
        ])
        noticeBanner = banner

        // Walking away is an answer, so the timeout routes through the same
        // decline path the button does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak banner] in
            banner?.dismissByTimeout()
        }
    }

    /// Help menu entry points. Presented directly rather than through Settings,
    /// which is a separate scene.
    @objc func cmdReportProblem() {
        guard admitShellAction(#selector(cmdReportProblem)) else { return }
        presentAlphaScreen(ReportProblemViewController(alpha: alpha))
    }

    @objc func cmdPrivacy() {
        guard admitShellAction(#selector(cmdPrivacy)) else { return }
        presentAlphaScreen(PrivacyViewController(alpha: alpha))
    }

    private func presentAlphaScreen(_ screen: UIViewController) {
        guard presentedViewController == nil else { return }
        hidePalettesForSheet()
        let nav = UINavigationController(rootViewController: screen)
        screen.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self, weak nav] _ in
                nav?.dismiss(animated: true) { self?.returnFocusAfterDismiss() }
            })
        presentAppStyled(nav)
    }

    @objc func cmdNewFile() {
        guard admitShellAction(#selector(cmdNewFile)) else { return }
        editor.newFile()
    }
    @objc func cmdSave() {
        // Note: on Mac a JS keydown path (`command:save` via native-host.ts) can
        // ALSO reach DocumentController.save() directly — out of this guard's
        // reach, but save is idempotent (second call sees a clean buffer).
        guard admitShellAction(#selector(cmdSave)) else { return }
        editor.save()
    }
    @objc func cmdCloseTab() {
        guard admitShellAction(#selector(cmdCloseTab)) else { return }
        if editor.hasOpenTabs {
            editor.closeActiveTab()
            return
        }
        // Empty window: Cmd+W closes the window itself, Mac-style. The app
        // keeps running (Catalyst apps stay alive with no windows on Mac).
        if let session = view.window?.windowScene?.session {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        }
    }
    @objc func cmdZoomIn() {
        guard admitShellAction(#selector(cmdZoomIn)) else { return }
        setZoom(Preferences.editorFontScale + 0.1)
    }
    @objc func cmdZoomOut() {
        guard admitShellAction(#selector(cmdZoomOut)) else { return }
        setZoom(Preferences.editorFontScale - 0.1)
    }
    @objc func cmdZoomReset() {
        guard admitShellAction(#selector(cmdZoomReset)) else { return }
        setZoom(1.0)
    }

    /// Zoom is one process-wide preference, which new tabs in any window
    /// read, so every window follows.
    private func setZoom(_ scale: Double) {
        Preferences.editorFontScale = scale            // clamps
        for root in liveRootsIncludingSelf() { root.applyEditorFontScale() }
    }
    @objc func cmdNextTab() {
        guard admitShellAction(#selector(cmdNextTab)) else { return }
        editor.nextTab()
    }
    @objc func cmdPrevTab() {
        guard admitShellAction(#selector(cmdPrevTab)) else { return }
        editor.previousTab()
    }
    @objc func cmdSettings() {
        guard admitShellAction(#selector(cmdSettings)) else { return }
        activateSettingsWindow()
    }
    @objc func cmdAddLocation() {
        guard admitShellAction(#selector(cmdAddLocation)) else { return }
        sidebar.presentAddLocationPicker()
    }

    // MARK: - Editing modes

    @objc func cmdCycleEditingMode() {
        guard admitShellAction(#selector(cmdCycleEditingMode)) else { return }
        setEditingMode(editingMode.next)
    }
    @objc func cmdEditingModeNormal() { setEditingMode(.normal) }
    @objc func cmdEditingModeZen() { setEditingMode(.zen) }
    @objc func cmdEditingModeTypewriter() { setEditingMode(.typewriter) }
    @objc func cmdEditingModeFocus() { setEditingMode(.focus) }

    /// Checkmark the active mode in the View → Editing Mode menu.
    override func validate(_ command: UICommand) {
        super.validate(command)
        if let mode = Self.editingModeByAction[command.action] {
            command.state = mode == editingMode ? .on : .off
        }
        if let mode = Self.viewModeByAction[command.action] {
            command.state = mode == Preferences.viewMode ? .on : .off
        }
    }

    private static let editingModeByAction: [Selector: EditingMode] = [
        #selector(cmdEditingModeNormal): .normal,
        #selector(cmdEditingModeZen): .zen,
        #selector(cmdEditingModeTypewriter): .typewriter,
        #selector(cmdEditingModeFocus): .focus,
    ]

    private static let viewModeByAction: [Selector: ViewMode] = [
        #selector(cmdViewModePreview): .preview,
        #selector(cmdViewModeMixed): .mixed,
        #selector(cmdViewModeSource): .source,
    ]

    /// Switch the editing mode: persist it, ship it to every editor surface
    /// (typewriter/focus live in editor-core), apply or lift zen's chrome, and
    /// update the pill's mode button.
    func setEditingMode(_ mode: EditingMode) {
        editingMode = mode
        Preferences.editingMode = mode
        applyEditorConfig()
        applyZenChrome(mode == .zen)
        footerBar.setEditingMode(mode)
    }

    /// Zen hides the tab row and forces the Library and the outline panel
    /// closed; the utility pill stays, as the way back out.
    ///
    /// docs/motion.md "Zen / normal": the band (and, on the fade lane, the
    /// titlebar chips) fades over `motionStandard`, the Library leaves through
    /// the sidebar slide, and the web-side resting offset glides by FLIP.
    /// Reduce Motion and `.instant` snap; every lane lands the same final state
    /// (`ZenTransitionContractTests` asserts it against fresh layouts).
    private func applyZenChrome(_ on: Bool) {
        guard isZen != on else { return }
        isZen = on
        // Zen owns chrome visibility; leave the auto-hide transforms neutral
        // in both directions so entering/leaving zen starts from chrome shown.
        revealChrome()
        let animated = motionAllowed
        let fade: TimeInterval? = animated ? ChalkMetrics.motionStandard : nil
        if on, displayMode != .secondaryOnly {
            // The Library leaves through the sidebar slide (whose settle equals
            // the fresh hidden layout); `animateSidebar` routes Reduce Motion /
            // `.instant` to the snap itself.
            animateSidebar(show: false)
        }
        if on, editor.isOutlinePanelVisible {
            editor.setOutlinePanelVisible(false, animated: animated)
        }
        if SceneDelegate.isAppKitGlueAvailable {
            // The strip's zen treatment: the toolbar keeps its height (the
            // window content never resizes) and the chips fade on zen's clock.
            // The glue hides the faded strip after the fade so alpha-0 chips
            // take no clicks, and un-hides it before fading back in.
            macStrip.postFaded(on, over: fade ?? 0)
            // The presentation pass applies the band's presence (full screen:
            // the UIKit band is the tab UI) and the editor's resting metrics.
            // `pendingZenBandFade` is the one lane that animates a presence
            // change. The resting-offset change glides web-side on the same
            // clock: armed before, cleared after, so only this pass's real
            // change consumes it.
            editor.nextChromeTopGlideDuration = fade
            pendingZenBandFade = fade
            applyMacChromePresentation()
            pendingZenBandFade = nil
            editor.nextChromeTopGlideDuration = nil
        } else {
            // No-glue fallback: the UIKit band is the tab UI and hiding it
            // moves the columns through the safe area, a webview bounds change
            // no fade can mask, so this lane snaps.
            UIView.performWithoutAnimation {
                headerBar.isHidden = on
                additionalSafeAreaInsets.top = on ? 0 : ChalkMetrics.headerHeight
            }
        }
        if !animated { UIView.performWithoutAnimation { view.layoutIfNeeded() } }
    }

    /// In-flight zen band fade generation: an instant presence write (or a
    /// newer fade) must turn a stale fade-out completion into a no-op — that
    /// completion hides the band, and hiding a band a newer transition just
    /// re-showed is the rapid-toggle flicker.
    private var zenBandFadeEpoch = 0

    /// The band's one presence seam: zen fades it over `fadeOver`
    /// (docs/motion.md "Zen / normal"); every other caller passes nil and gets
    /// an instant write. Both lanes land the same final state (`isHidden` set,
    /// alpha 1), which the transition matrix asserts under `.instant`.
    private func setBandHidden(_ hidden: Bool, fadeOver duration: TimeInterval?) {
        guard headerBar.isHidden != hidden else { return }
        zenBandFadeEpoch += 1
        guard let duration, duration > 0, headerBar.window != nil else {
            headerBar.layer.removeAllAnimations()
            headerBar.isHidden = hidden
            headerBar.alpha = 1
            return
        }
        let epoch = zenBandFadeEpoch
        if hidden {
            UIView.animate(withDuration: duration, delay: 0,
                           options: [.beginFromCurrentState, .curveEaseInOut]) {
                self.headerBar.alpha = 0
            } completion: { finished in
                guard finished, epoch == self.zenBandFadeEpoch else { return }
                self.headerBar.isHidden = true
                self.headerBar.alpha = 1
            }
        } else {
            headerBar.isHidden = false
            headerBar.alpha = 0
            UIView.animate(withDuration: duration, delay: 0,
                           options: [.beginFromCurrentState, .curveEaseInOut]) {
                self.headerBar.alpha = 1
            }
        }
    }

    // MARK: - Settings / appearance

    /// Tell the AppKit glue which appearance this app is in.
    ///
    /// Its colours resolve against the window's NSAppearance, which follows the
    /// system appearance unless set, so an app forced to Light on a dark Mac
    /// would paint the titlebar cover dark over a cream editor.
    func pushAppearanceToGlue() {
        guard SceneDelegate.isAppKitGlueAvailable, !macStrip.isDetached else { return }
        let style: TabStripBridge.Appearance
        switch Preferences.themePreference.interfaceStyle {
        case .dark: style = .dark
        case .light: style = .light
        default: style = .system
        }
        NotificationCenter.default.post(
            name: TabStripBridge.windowAppearance, object: nil,
            userInfo: [TabStripBridge.styleKey: style.rawValue,
                       TabStripBridge.themeKey: Preferences.colorTheme.rawValue])
    }

    func applyThemePreference() {
        pushAppearanceToGlue()
        let style = Preferences.themePreference.interfaceStyle
        guard overrideUserInterfaceStyle != style
            || traitOverrides.chalkTheme != Preferences.colorTheme else {
            // Same override and theme (the Settings broadcast re-applies on
            // every general change): nothing flips, so nothing to cover, but a
            // presented sheet may still need pinning.
            applyAppearanceToPresentedChain()
            return
        }
        runAppearanceTransition(flippingTo: style)
    }

    /// A presented sheet was pinned to the preference at present-time (see
    /// presentAppStyled below); walk the chain so a theme change made while
    /// one is open reaches it too, not just the main window.
    private func applyAppearanceToPresentedChain() {
        var presented = presentedViewController
        while let controller = presented {
            controller.applyChalkAppearance()
            presented = controller.presentedViewController
        }
    }

    /// docs/motion.md "Appearance": a theme change is a covered transition.
    /// Snapshot the active surface (old colours) → opaque cover over the
    /// webview's rect → in one turn: the override flip, the `data-theme` push,
    /// and a cross-dissolve on headerBar, footerBar and the sidebar's view
    /// separately (never the root view: its transition snapshot includes the
    /// webview's remote layer, which comes back empty) → the in-page paint gate
    /// → cover fade (`motionFast`). `WebPaintGate` owns the ordering and the
    /// guaranteed release, as for the sidebar slide's settle.
    ///
    /// Non-nil `style` is the preference route (the override flips inside the
    /// covered turn). Nil is the system route (Auto): the OS has already
    /// flipped the trait and the native chrome, so the cover owns only the
    /// page's async repaint, the slow, torn half. The page flips only under the
    /// cover because the container's own trait hook stands down
    /// (`hostOwnsAppearanceTransitions`).
    ///
    /// Reduce Motion (and `.instant`) keep the cover with zero-duration fades:
    /// the mismatch flash it prevents is correctness, not motion.
    private func runAppearanceTransition(flippingTo style: UIUserInterfaceStyle?) {
        let animated = motionAllowed
        // A theme change mid-theme-change: the older cover must not fade over
        // the newer transition's pixels. Cancel releases it instantly and
        // no-ops its pending callbacks.
        appearanceSettle?.cancel()
        appearanceSettle = nil

        let flip: () -> Void = { [weak self] in
            guard let self else { return }
            // The chrome dissolves are begun FIRST: UIView.transition
            // captures each view's current (old-theme) presentation and
            // cross-fades to whatever the same turn's trait flip restyles.
            if animated {
                let chrome: [UIView?] = [self.headerBar, self.footerBar, self.sidebar.viewIfLoaded]
                for view in chrome.compactMap({ $0 }) where view.window != nil {
                    UIView.transition(with: view, duration: ChalkMetrics.motionStandard,
                                      options: [.transitionCrossDissolve, .beginFromCurrentState],
                                      animations: {})
                }
            }
            if let style {
                self.isApplyingThemeOverride = true
                self.overrideUserInterfaceStyle = style
                // The theme flips in the same turn; the push below passes it
                // explicitly rather than reading the trait back.
                self.traitOverrides.chalkTheme = Preferences.colorTheme
                self.isApplyingThemeOverride = false
                #if DEBUG
                self.appearanceTransitionTrailForTesting.append("style-applied")
                #endif
            }
            // The page flips in the SAME turn (`data-theme`, `data-palette`); the
            // container's own trait hook is silenced while a root
            // orchestrates, so this is the one push. Explicit styles are
            // passed through; Auto reads the live trait AFTER the flip.
            let dark: Bool
            switch style {
            case .some(.dark): dark = true
            case .some(.light): dark = false
            default: dark = self.traitCollection.userInterfaceStyle == .dark
            }
            self.editor.pushAppearance(dark: dark, theme: Preferences.colorTheme)
            #if DEBUG
            self.appearanceTransitionTrailForTesting.append("appearance-pushed")
            #endif
            self.applyAppearanceToPresentedChain()
        }

        guard let seams = coverSeams(for: .appearance),
              let editorView = editor.viewIfLoaded, editorView.window != nil else {
            // No surface to mask (no open tab, or not hosted yet — the
            // viewDidLoad call lands here): nothing can tear, apply directly.
            flip()
            return
        }

        var timing = WebPaintGate.Timing()
        if !animated { timing.fade = 0 } // Reduce Motion: covers stay, fades zero
        #if DEBUG
        if let injected = appearanceTimingForTesting { timing = injected }
        #endif
        let settle = WebPaintGate(
            snapshotter: seams.snapshotter,
            paintGate: seams.paintGate,
            makeCover: { [weak self] image in
                let cover = self?.makeWebCover(over: editorView, bitmap: image, of: seams.bitmapSource)
                #if DEBUG
                if cover != nil { self?.appearanceTransitionTrailForTesting.append("cover-installed") }
                #endif
                return cover
            },
            reflow: flip,
            timing: timing)
        appearanceSettle = settle
        settle.begin()
    }

    /// Force a presented sheet to the app's chosen appearance. On Catalyst a
    /// `.formSheet` lives in its own UIWindow and would otherwise follow the
    /// system appearance; `.unspecified` (Auto) follows the system, like the
    /// main window.
    ///
    /// Also makes this controller the presentation delegate, so interactive
    /// dismissal returns focus too. That
    /// callback never fires for programmatic `dismiss()`, so it never doubles
    /// the explicit `onDismiss` paths; both end at `returnFocusAfterDismiss()`.
    private func presentAppStyled(_ controller: UIViewController) {
        controller.applyChalkAppearance()
        controller.presentationController?.delegate = self
        present(controller, animated: false)
    }

    /// Single sink for "a sheet just went away, give the editor focus back" —
    /// called from both the explicit dismiss paths' `onDismiss` closures and
    /// from interactive dismissal via the presentation controller delegate
    /// below.
    private func returnFocusAfterDismiss() {
        editor.focusActiveSurface()
    }

    /// Focus the Settings window, opening it only if there isn't one.
    ///
    /// Activating the existing session rather than requesting a second is what
    /// keeps Cmd+, from stacking up Settings windows — `requestSceneSessionActivation`
    /// with a nil session always makes a new one.
    private func activateSettingsWindow() {
        // Identify by delegate rather than title: the title carries an
        // invisible marker, and the restoration activity is deliberately nil.
        let existing = UIApplication.shared.openSessions.first {
            $0.scene?.delegate is SettingsSceneDelegate
        }
        if let existing {
            UIApplication.shared.requestSceneSessionActivation(
                existing, userActivity: nil, options: nil)
            return
        }
        let activity = NSUserActivity(activityType: ChalkActivity.settingsType)
        UIApplication.shared.requestSceneSessionActivation(
            nil, userActivity: activity, options: nil)
    }

    /// The palette overlays are child views, not presentations, so a
    /// `presentedViewController` guard doesn't cover them: hide them before
    /// presenting a sheet, or the sheet stacks over a palette.
    private func hidePalettesForSheet() {
        if quickOpenHost.isVisible { hideQuickOpen(then: nil) }
        if outlineHost.isVisible { hideOutlinePalette(then: nil) }
    }

    // MARK: - Opening what the Library lists

    /// The one fork every Library open path runs through (sidebar click, row
    /// menu, Quick Open). The tree lists documents AND the images/PDFs those
    /// documents embed, and only documents can become a tab: handing a png to
    /// `editor.open` would decode its bytes as Markdown, so assets divert to
    /// the preview sheet. `inNewTab` is a document-only distinction
    /// (browse-reuse vs always-a-fresh-tab); a preview has no tab to reuse.
    func openFromLibrary(_ url: URL, inNewTab: Bool = false) {
        if FileTree.kind(of: url) == .asset {
            previewAsset(url)
        } else {
            editor.open(url: url, reuseCurrentIfClean: !inNewTab)
        }
    }

    /// The live preview sheet. Tracked rather than trusting
    /// `presentedViewController` alone because a row click can arrive twice in
    /// one run loop turn (the click path and the collection view's selection),
    /// and the second must not stack a second sheet.
    private weak var livePreview: UIViewController?

    private func previewAsset(_ url: URL) {
        // Recorded before the guards: this is the routing fact the tests pin,
        // whether or not the modal slot happened to be free.
        lastPreviewedAsset = url
        guard livePreview == nil, presentedViewController == nil else { return }
        hidePalettesForSheet()
        let sheet = AssetPreviewViewController.inNavigationController(url: url)
        livePreview = sheet
        presentAppStyled(sheet)
    }

    /// Last URL routed to the preview sheet (read by AssetPreviewRoutingTests).
    private(set) var lastPreviewedAsset: URL?

    // MARK: - Quick Open

    /// Mounted once as a child (not presented) so opening is a plain view toggle
    /// with no modal-presentation animation. Kept alive across opens so it can
    /// paint its last file index instantly (via `prepareForReuse`) instead of
    /// flashing empty while the async enumeration runs. onOpen/onDismiss/onClose
    /// are wired once here; closing returns focus to the editor so typing resumes
    /// without a click.
    private lazy var quickOpenVC: QuickOpenViewController = {
        let vc = QuickOpenViewController()
        // ↩ browses in place (reuse an unedited tab, like a sidebar click);
        // ⌘↩ always opens a fresh tab (the palette's footer hint).
        vc.onOpen = { [weak self] url, inNewTab in
            self?.openFromLibrary(url, inNewTab: inNewTab)
        }
        vc.onDismiss = { [weak self] in self?.returnFocusAfterDismiss() }
        // The palette asks the host to hide the overlay, then runs `then` (open
        // + focus-return).
        vc.onClose = { [weak self] then in self?.hideQuickOpen(then: then) }
        return vc
    }()

    /// Mount the palette as a hidden glass card over the scrim; the host owns
    /// the views and the animation, this owns the containment and the wiring.
    private func setUpQuickOpenOverlay() {
        addChild(quickOpenVC)
        quickOpenHost.mount(in: view, content: quickOpenVC.view) { [weak self] in
            self?.hideQuickOpen { self?.returnFocusAfterDismiss() }
        }
        quickOpenVC.onContentHeightChanged = { [weak self] in self?.quickOpenHost.setCardHeight($0) }
        quickOpenVC.didMove(toParent: self)
    }

    private func presentQuickOpen() {
        // Don't stack the palette over itself or over a presented sheet (Settings).
        guard !quickOpenHost.isVisible, presentedViewController == nil else { return }
        // The palettes are mutually exclusive.
        if outlineHost.isVisible { hideOutlinePalette(then: nil) }
        postStripScrim(true)
        quickOpenVC.prepareForReuse()
        #if DEBUG
        quickOpenVC.openCommandTime = CACurrentMediaTime()
        #endif
        quickOpenHost.present()
        quickOpenVC.didReveal()

        // Enumerating every Location can take seconds on big folders; never on
        // the main thread. The palette paints its cached index immediately (via
        // prepareForReuse) and this refreshes it.
        let roots = libraryRoots
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = roots.flatMap { FileTree.allFiles(in: $0) }
            DispatchQueue.main.async {
                self?.quickOpenVC.setFiles(files)
            }
        }
    }

    /// Hide the palette overlay (short fade), then run `then` — typically the
    /// open-file + focus-return the palette requested. `then` fires immediately,
    /// not on the fade's completion, so opening a file still feels instant; the
    /// scrim just melts away over the editor that's already taking focus.
    private func hideQuickOpen(then: (() -> Void)? = nil) {
        guard quickOpenHost.isVisible else { then?(); return }
        // Only when no OTHER palette is taking over: they are mutually
        // exclusive, and the handover must not flash the strip back to full
        // brightness between them.
        if !outlineHost.isVisible { postStripScrim(false) }
        quickOpenHost.dismiss()
        then?()
    }

    // MARK: - Outline palette

    /// Mounted once as a child, like Quick Open. Kept alive across opens; the
    /// outline itself is refetched every open (`prepareForReuse` drops it —
    /// it's per-document, unlike the file index).
    private lazy var outlinePaletteVC: OutlinePaletteViewController = {
        let vc = OutlinePaletteViewController()
        vc.onJump = { [weak self] line in
            // Belt to handleTabsChanged's suspenders: the line numbers belong
            // to the tab the snapshot was fetched from — never scroll a
            // different document to them.
            guard let self, self.currentActiveTabID == self.outlineSnapshotTabID else { return }
            self.editor.revealLine(line)
        }
        vc.onDismiss = { [weak self] in self?.returnFocusAfterDismiss() }
        vc.onClose = { [weak self] then in self?.hideOutlinePalette(then: then) }
        return vc
    }()

    /// Same host, same recipe as `setUpQuickOpenOverlay`.
    private func setUpOutlineOverlay() {
        addChild(outlinePaletteVC)
        outlineHost.mount(in: view, content: outlinePaletteVC.view) { [weak self] in
            self?.hideOutlinePalette { self?.returnFocusAfterDismiss() }
        }
        outlinePaletteVC.onContentHeightChanged = { [weak self] in self?.outlineHost.setCardHeight($0) }
        outlinePaletteVC.didMove(toParent: self)
    }

    private func presentOutlinePalette() {
        guard !outlineHost.isVisible, presentedViewController == nil else { return }
        if quickOpenHost.isVisible { hideQuickOpen(then: nil) }
        postStripScrim(true)
        outlinePaletteVC.prepareForReuse()
        #if DEBUG
        outlinePaletteVC.openCommandTime = CACurrentMediaTime()
        #endif
        outlineHost.present {
            // Release the webview's DOM focus before the palette grabs the
            // keyboard, or WebKit re-asserts first responder behind the overlay
            // and every keystroke dies (the ⌘P-forwarded open originates inside
            // WebKit's own key processing).
            editor.blurActiveSurface()
            Self.outlineLog.info("presentOutlinePalette: blur sent, revealing")
        }
        outlinePaletteVC.didReveal()

        // One bridge round trip; the guards drop a snapshot that lands after
        // the palette was dismissed, after a quick close/reopen superseded
        // this open (generation), or after the active tab changed underneath
        // the fetch (identity — the snapshot must never paint another tab's
        // outline). A nil snapshot (no tab, editor still booting) paints the
        // empty state — never cached, every open refetches.
        outlineFetchGeneration += 1
        let generation = outlineFetchGeneration
        let tabID = currentActiveTabID
        outlineSnapshotTabID = tabID
        Self.outlineLog.info("outline fetch dispatched gen=\(generation, privacy: .public)")
        editor.fetchActiveOutline { [weak self] snapshot in
            Self.outlineLog.info("outline fetch completed gen=\(generation, privacy: .public) items=\(snapshot?.items.count ?? -1, privacy: .public)")
            guard let self, self.outlineHost.isVisible,
                  generation == self.outlineFetchGeneration,
                  tabID == self.currentActiveTabID else { return }
            self.outlinePaletteVC.setSnapshot(snapshot ?? .empty)
        }
    }

    /// Mirror of `hideQuickOpen` — `then` fires immediately so the jump feels
    /// instant while the scrim melts over the editor already scrolling.
    private func hideOutlinePalette(then: (() -> Void)? = nil) {
        guard outlineHost.isVisible else { then?(); return }
        // See hideQuickOpen: the other palette may be taking over.
        if !quickOpenHost.isVisible { postStripScrim(false) }
        outlineHost.dismiss {
            Self.outlineLog.info("hideOutlinePalette")
            outlinePaletteVC.willHide() // cancel pending grabFocus retries
        }
        then?()
    }
}

/// The seam between the scene root and the titlebar-strip protocol: the root
/// answers what the bridge cannot know (its window, its key state, the scrim
/// decision) and takes the actions the bridge must not
/// (measuring the divider, pushing the appearance, presenting full screen,
/// acting on tabs).
extension RootSplitViewController: MacStripBridgeHost {
    /// `viewIfLoaded`, never `view` (see
    /// `MacStripBridgeHost.stripBridgeWindow`).
    var stripBridgeWindow: UIWindow? { viewIfLoaded?.window }

    var stripBridgeWindowIsKey: Bool { viewIfLoaded?.window?.isKeyWindow == true }

    var stripBridgeScrimmed: Bool { lastStripScrimmed }

    func stripBridgePushLeadingInset() { pushStripLeadingInset() }

    func stripBridgeDidEstablishWindow() { pushAppearanceToGlue() }

    func stripBridgeApplyFullScreen(_ on: Bool) {
        guard on != isMacFullscreen else { return }
        isMacFullscreen = on
        applyMacChromePresentation()
    }

    func stripBridgePerform(_ action: MacStripBridge.StripAction) {
        switch action {
        case .new: cmdNewFile()
        case .select(let id): editor.selectTab(id: id)
        case .close(let id): editor.requestCloseTab(id: id)
        case .move(let id, let index): editor.moveTab(id: id, to: index)
        }
    }
}

extension RootSplitViewController: UIAdaptivePresentationControllerDelegate {
    /// Fires only when a sheet is dismissed interactively, never for a programmatic `dismiss()`, so it
    /// never doubles the explicit `onDismiss` paths. Without it, closing a
    /// sheet that way would skip focus-return.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        returnFocusAfterDismiss()
    }
}

#if DEBUG
extension RootSplitViewController {
    /// Test hooks (ChalkTests): zen chrome state, without exposing the views.
    var isHeaderHiddenForTesting: Bool { headerBar.isHidden }

    /// Header band geometry.
    var headerBandHeightForTesting: CGFloat { headerHeight?.constant ?? -1 }
    /// Utility-pill placement (FooterPillPlacementTests), in root-view coords.
    var footerPillFrameForTesting: CGRect { footerBar.frame }
    /// What the pill's editing-mode menu would check right now. Reads through
    /// the same closure the menu builds from, so a test can prove one window's
    /// pill is unaffected by another window's mode change.
    var pillEditingModeForTesting: EditingMode? { footerBar.currentEditingMode?() }
    var editorChromeTopInsetForTesting: Double { editor.chromeTopInsetForTesting }

    var editorMeasureForTesting: Double? { editor.lastPushedMeasure }

    var editorLineHeightForTesting: Double? { editor.lastPushedLineHeight }

    var editorTextAlignForTesting: String? { editor.lastPushedTextAlign?.cssValue }

    /// Library open routing (AssetPreviewRoutingTests): assets go to the
    /// preview sheet, documents to a tab.
    var lastPreviewedAssetForTesting: URL? { lastPreviewedAsset }
    var editorForTesting: EditorContainerViewController { editor }
    /// The view the slide transforms. A diagnostic needs it to check the
    /// transform does not reach the editor.
    func sidebarColumnContainerForTesting() -> UIView? { sidebarColumnContainer() }

    /// Outline palette wiring (OutlineToggleTests).
    var isOutlineVisibleForTesting: Bool { outlineHost.isVisible }
    var isOutlinePanelVisibleForTesting: Bool { editor.isOutlinePanelVisible }
    /// The band's trailing cut-out in root coordinates, nil when none.
    var bandTrailingHoleForTesting: CGRect? {
        headerBar.paintTrailingHoleForTesting.map { view.convert($0, from: headerBar) }
    }
    func setOutlinePanelForTesting(_ visible: Bool) { editor.setOutlinePanelVisible(visible, animated: false) }
    /// Drive the web-forwarded shell command lane (`editor.onShellCommand`).
    func simulateShellCommandForTesting(_ name: String) { editor.onShellCommand?(name) }
    var lastStripScrimmedForTesting: Bool { lastStripScrimmed }
    /// The recorded strip divider (the strip's own pixels live in a bundle no
    /// test target links, so the decision IS the evidence).
    var lastStripDividerXForTesting: CGFloat { macStrip.lastDividerX }
    var isQuickOpenVisibleForTesting: Bool { quickOpenHost.isVisible }
    /// Palette card geometry in the root view's coordinates
    /// (PaletteCenteringTests). `.null` when the card isn't mounted yet.
    var quickOpenCardFrameForTesting: CGRect { cardFrameInRoot(quickOpenHost.card) }
    var outlineCardFrameForTesting: CGRect { cardFrameInRoot(outlineHost.card) }
    private func cardFrameInRoot(_ card: UIView?) -> CGRect {
        guard let card, let host = card.superview else { return .null }
        return host.convert(card.frame, to: view)
    }
    var outlinePaletteVCForTesting: OutlinePaletteViewController { outlinePaletteVC }
    /// Drives the real `onTabsChanged` sink with a canned strip, so
    /// OutlineToggleTests can pin the palette's tab-identity guard without
    /// spinning up WKWebView-backed tabs.
    func simulateTabsChangedForTesting(_ items: [TabItem]) { handleTabsChanged(items) }

    /// Drives the Mac full-screen chrome switch that nothing else in a test can
    /// reach.
    ///
    /// `isMacFullscreen` is written only from glue notifications
    /// (`handleWindowFullScreenChange`, the bind payload), never from the
    /// window's size, so without this every `fullscreen-*` cell would be
    /// its windowed sibling. It sets the same flag and runs the same
    /// presentation path, but does not make the window full screen; nothing
    /// in-process can. `isAppKitGlueAvailableForTesting` says whether the swap
    /// can happen at all: `applyMacChromePresentation` no-ops without the glue,
    /// and the suite reports that rather than silently re-running windowed.
    func setMacFullscreenForTesting(_ on: Bool) {
        guard isMacFullscreen != on else { return }
        isMacFullscreen = on
        applyMacChromePresentation()
        view.layoutIfNeeded()
    }

    var isAppKitGlueAvailableForTesting: Bool { SceneDelegate.isAppKitGlueAvailable }

    /// The chrome's geometry as a value, for the invariant suite.
    ///
    /// Every rect is read from a live view and converted into `view`'s
    /// coordinates. Nothing here may be computed from a constant: the point is
    /// to describe what the app actually laid out.
    func chromeLayout(for state: UIState) -> ChromeLayout {
        let bandFrame = headerBar.isHidden ? .zero : headerBar.frame
        let paint = headerBar.isHidden
            ? CGRect.zero
            : view.convert(headerBar.paintFrameForTesting, from: headerBar)
        // The hole follows the paint: a hidden band reports neither. The stored
        // mask can be stale while hidden (unreachable on screen), and reporting
        // it would trip transition equality over invisible state.
        let hole = headerBar.isHidden
            ? nil
            : headerBar.paintHoleForTesting.map { view.convert($0, from: headerBar) }
        let trailingHole = headerBar.isHidden
            ? nil
            : headerBar.paintTrailingHoleForTesting.map { view.convert($0, from: headerBar) }
        // A hidden band's chip strip is parked wherever it was last laid out;
        // reporting that stale frame would let a window-bounds check trip over
        // furniture nobody can see. Zero it like `bandFrame` and `paint`.
        let tabStripFrame = headerBar.isHidden
            ? CGRect.zero
            : view.convert(headerBar.tabStrip.frame, from: headerBar)
        let panel: CGRect? = {
            guard displayMode != .secondaryOnly,
                  let sidebarView = sidebar.viewIfLoaded else { return nil }
            return view.convert(sidebar.panelFrameForTesting, from: sidebarView)
        }()
        // The active chip, live, in root coordinates — absent exactly when
        // the strip is (a hidden band's chip would be parked stale geometry,
        // same reasoning as `tabStripFrame` above).
        let activeChip: CGRect? = headerBar.isHidden
            ? nil
            : headerBar.tabStrip.activeTabFrameForTesting
                .map { view.convert($0, from: headerBar.tabStrip) }
        // The pill stands in every state since Paper; `.zero` here would mean
        // something hid it, which is a regression, not a state.
        let pill = footerBar.isHidden ? CGRect.zero : footerBar.frame
        // The spec corner for the pill — the constants the live
        // constraints are supposed to realize (FooterPillPlacementTests).
        // Labelled spec in ChromeLayout; the LIVE frame above is the geometry.
        let pillCorner = CGPoint(x: ChalkMetrics.footerPillMargin,
                                 y: ChalkMetrics.footerPillMargin)
        let editorContent: CGRect = editor.viewIfLoaded
            .map { view.convert(editor.contentViewFrameForTesting, from: $0) } ?? .zero
        // The reserve, from INDEPENDENT truth (never the expression that
        // computes the editor's resting inset, or the resting-line rule is a
        // tautology): `chromeReserve` reads the band's live maxY, or the
        // system's own inset when the band is not the reserving chrome. The
        // same property the Library starts its list on, so the report cannot
        // drift from what the two columns actually align to.
        let reserveTop = chromeReserve
        let firstRowTop: CGFloat?
        let firstHeaderTop: CGFloat?
        let scrollOffset: CGFloat?
        if panel != nil, let sidebarView = sidebar.viewIfLoaded {
            firstRowTop = sidebar.firstRowFrameForTesting
                .map { view.convert($0, from: sidebarView).minY }
            firstHeaderTop = sidebar.firstHeaderFrameForTesting
                .map { view.convert($0, from: sidebarView).minY }
            scrollOffset = sidebar.libraryScrollOffsetForTesting
        } else {
            firstRowTop = nil
            firstHeaderTop = nil
            scrollOffset = nil
        }
        // The active name and the underline that tracks it, in root
        // coordinates — absent exactly where the UIKit row is not the tab UI.
        let activeLabel: CGRect? = headerBar.isHidden
            ? nil
            : headerBar.tabStrip.activeLabelFrameForTesting
                .map { view.convert($0, from: headerBar.tabStrip) }
        let activeUnderline: CGRect? = headerBar.isHidden
            ? nil
            : headerBar.tabStrip.activeUnderlineFrameForTesting
                .map { view.convert($0, from: headerBar.tabStrip) }
        // The windowed titlebar strip as this scene last decided it (the
        // strip's own pixels live in a bundle no test links). `visible` is the
        // recorded post and nothing else: a derived value would let
        // `stripVisibilityMatchesTheState` compare a derived answer with the
        // oracle and pass whatever the glue showed.
        let macStrip: MacStripExpectation? = SceneDelegate.isAppKitGlueAvailable
            ? MacStripExpectation(
                dividerX: macStrip.lastDividerX * ChalkMetrics.displayScale,
                visible: macStrip.lastVisible,
                faded: macStrip.lastFaded)
            : nil
        return ChromeLayout(
            state: state,
            root: view.bounds,
            band: bandFrame,
            bandPaint: paint,
            bandPaintHole: hole,
            libraryPanel: panel,
            tabStrip: tabStripFrame,
            editorRestingTop: CGFloat(editorChromeTopInsetForTesting),
            restingPad: ChalkMetrics.editorRestingPad,
            libraryRowHeight: ChalkMetrics.sidebarRowHeight,
            underlineGap: ChalkMetrics.tabUnderlineGap,
            footerPill: pill,
            pillCorner: pillCorner,
            editorContent: editorContent,
            reserveTop: reserveTop,
            safeLeading: view.safeAreaInsets.left,
            libraryFirstRowTop: firstRowTop,
            libraryFirstHeaderTop: firstHeaderTop,
            libraryScrollOffset: scrollOffset,
            activeChip: activeChip,
            activeTabLabel: activeLabel,
            activeTabUnderline: activeUnderline,
            macStrip: macStrip,
            outlinePanel: editor.viewIfLoaded.flatMap { editorView in
                editor.outlinePanelFrame.map { view.convert($0, from: editorView) }
            },
            outlinePanelIsOverlay: editor.outlinePanelIsOverlay,
            outlinePanelPushMinimum: ChalkMetrics.outlinePanelPushMinimumEditorWidth,
            bandPaintTrailingHole: trailingHole)
    }

    /// Drive one user-level chrome toggle through the REAL entry points,
    /// minus `admitShellAction`'s coalescer (its job is de-duplicating one
    /// physical key press arriving over two delivery lanes; a test step is
    /// one call). The product rules stay in the product: the zen refusal
    /// lives in `animateSidebar`, the Library close in `applyZenChrome`.
    ///
    /// `.window` is only half-driveable from inside the process: it flips the
    /// same flag the glue's full-screen notification would.
    func applyTransitionForTesting(_ step: TransitionStep) {
        switch step {
        case .sidebar(let visible):
            // cmdToggleSidebar's body: an explicit chrome interaction always
            // brings auto-hidden chrome back, then the sidebar moves. The
            // change-guard mirrors the command's toggle semantics — the real
            // path can never ask for the state it is already in, and
            // animateSidebarIn would slide an already-visible column.
            guard visible != (displayMode != .secondaryOnly) else { return }
            revealChrome()
            animateSidebar(show: visible)
        case .window(let mode):
            setMacFullscreenForTesting(mode == .fullscreen)
        case .zen(let on):
            setEditingMode(on ? .zen : .normal)
        case .outline(let visible):
            // cmdToggleOutlinePanel's body: zen owns the chrome, so opening
            // the outline panel into it is refused rather than applied — the
            // same rule `UIState.applying(_:)` writes down for this step.
            // `editor.setOutlinePanelVisible` itself knows nothing of zen
            // (it lives one layer below), so the refusal has to happen here.
            guard visible != editor.isOutlinePanelVisible else { return }
            if visible, isZen { return }
            revealChrome()
            editor.setOutlinePanelVisible(visible, animated: false)
        }
    }

    /// The Library list's scroll offset (see the sidebar seams).
    var libraryScrollOffsetForTesting: CGFloat { sidebar.libraryScrollOffsetForTesting }
    /// The Library itself, for the tests that drive its own seams (the chrome
    /// floor, the layout fixed point).
    var sidebarForTesting: SidebarViewController { sidebar }

    /// Where the chrome that reserves space above the text ENDS, in this
    /// root's coordinates — the floor the editor's first line rests below, and
    /// the line the Library starts its list on.
    var chromeReserveForTesting: CGFloat { chromeReserve }

    func setLibraryScrollOffsetForTesting(_ offset: CGFloat) {
        sidebar.setLibraryScrollOffsetForTesting(offset)
    }

    /// Point the Library at the given folders without touching the real
    /// `LocationStore`, whose security-scoped bookmarks a test must never
    /// write.
    func setLibraryLocationsForTesting(_ urls: [URL]) {
        sidebar.locationsProvider = {
            urls.map { Location(id: $0.lastPathComponent, name: $0.lastPathComponent, url: $0) }
        }
        sidebar.reload()
    }

    /// Whether the hand-rolled sidebar slide still owns any state (a sliding
    /// column or a live settle). True mid-flight; false at rest — a rapid
    /// re-toggle must end false or the next slide starts from a lie.
    var isSidebarTransitionInFlightForTesting: Bool { isSidebarTransitionInFlight }
}

extension RootSplitViewController {
    /// Applies CHALK_AUDIT_STATE after first layout. States: tabs1 tabs5 tabs12
    /// tabs12to3 longtabs | promo-editor promo-library promo-outline |
    /// sidebar-deep sidebar-empty | tabs6-sidebar | preview | quickopen
    /// quickopen-long outline fsoutline fstabs5 | settings | empty | stressdoc
    /// | scale06 scale25 | narrow
    func applyAuditStateIfRequested() {
        guard let state = AuditMode.requestedState else { return }
        // The stress tree (120 files, six levels, an 80-character name) exists
        // to break the layout. It must not appear in a landing-page shot, and
        // it lands inside the default location, so the promo states skip it.
        let fixtures = state.hasPrefix("promo-") ? SampleContent.documentsURL
                                                 : AuditMode.seedFixtures()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            switch state {
            case "tabs1": break // Welcome.md is already open
            case "tabs5":
                for name in ["alpha.md", "beta.md", "gamma.tex", "delta.md"] {
                    editor.open(url: fixtures.appendingPathComponent(name))
                }
            case "longtabs":
                editor.open(url: fixtures.appendingPathComponent(
                    "an-extremely-long-file-name-that-should-truncate-in-the-tab-strip-not-overflow-it.md"))
                editor.open(url: fixtures.appendingPathComponent("many")
                    .appendingPathComponent("001-lecture-notes-with-a-very-long-descriptive-title.md"))
            case "tabs12":
                for name in ["alpha.md", "beta.md", "gamma.tex", "delta.md", "epsilon.md",
                             "zeta.md", "eta.md", "theta.tex", "iota.md", "kappa.md", "lambda.md"] {
                    editor.open(url: fixtures.appendingPathComponent(name))
                }
            case "tabs12to3":
                // Overflow transition: open 12 (chevron + fades appear), then
                // close back to 3 via the normal close path — the chevron and
                // trailing fade must retract once the tabs fit again.
                for name in ["alpha.md", "beta.md", "gamma.tex", "delta.md", "epsilon.md",
                             "zeta.md", "eta.md", "theta.tex", "iota.md", "kappa.md", "lambda.md"] {
                    editor.open(url: fixtures.appendingPathComponent(name))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
                    editor.closeAllButFirstForAudit(keeping: 3)
                }
            // Landing-page shots. Real-looking work, not the stress tree.
            case "promo-editor":
                editor.closeAllTabsForAudit()
                editor.open(url: AuditMode.seedPromoContent()
                    .appendingPathComponent("Panel bias/estimator-bias.md"))
            case "promo-library":
                AuditMode.seedPromoContent()
                locationStore.add(url: SampleContent.documentsURL)
                editor.closeAllTabsForAudit()
                sidebar.reload(); setSidebarVisible(true); sidebar.expandAll()
                editor.open(url: SampleContent.documentsURL
                    .appendingPathComponent("Research/Panel bias/estimator-bias.md"))
            case "promo-outline":
                editor.closeAllTabsForAudit()
                editor.open(url: AuditMode.seedPromoContent()
                    .appendingPathComponent("Panel bias/estimator-bias.md"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                    cmdToggleOutline()
                }
            case "sidebar-deep":
                locationStore.add(url: fixtures.appendingPathComponent("deep"))
                sidebar.reload(); setSidebarVisible(true); sidebar.expandAll()
            case "tabs6-sidebar":
                // A crowded strip and the Library open together: the one
                // configuration that shows the chips short of room
                // (docs/issues/2026-08-18-mac-tabs-vanish-when-the-library-is-open.md).
                locationStore.add(url: fixtures)
                sidebar.reload(); setSidebarVisible(true)
                for name in ["alpha.md", "beta.md", "gamma.tex", "delta.md", "epsilon.md"] {
                    editor.open(url: fixtures.appendingPathComponent(name))
                }
            case "preview":
                // Asset row → preview sheet (the Library lists images/PDFs).
                locationStore.add(url: fixtures)
                sidebar.reload(); setSidebarVisible(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                    openFromLibrary(fixtures.appendingPathComponent("figure.png"))
                }
            case "sidebar-empty":
                locationStore.add(url: fixtures.appendingPathComponent("empty-location"))
                sidebar.reload(); setSidebarVisible(true)
            case "quickopen": cmdQuickOpen()
            case "quickopen-long":
                locationStore.add(url: fixtures.appendingPathComponent("many"))
                cmdQuickOpen()
                // Without a query the palette shows files.prefix(50) — identical
                // to plain quickopen; filter to surface the 120 long names.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                    quickOpenVC.setQueryForAudit("lecture")
                }
            case "settings": cmdSettings()
            case "outline":
                editor.open(url: fixtures.appendingPathComponent("outline.md"))
                // The webview needs to boot and `init` before the outline
                // exists to fetch; 2s matches the tabs12to3 settle delay.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
                    cmdToggleOutline()
                }
            case "fsoutline":
                // Replays the full-screen drop timeline
                // (docs/issues/2026-08-17-fullscreen-drops-when-outline-opens.md):
                // heavy doc, enter full screen via the glue's debug hook (real
                // toggleFullScreen), then open the outline shortly after
                // didEnterFullScreen. The delay is tunable:
                // CHALK_AUDIT_FS_DELAY (seconds).
                editor.open(url: fixtures.appendingPathComponent("stress.md"))
                let fsDelay = ProcessInfo.processInfo.environment["CHALK_AUDIT_FS_DELAY"]
                    .flatMap(Double.init) ?? 0.25
                // A reference box, not a captured `var`: the observer removes
                // itself, so the closure reads a token assigned only after it
                // exists, and mutating a captured local across a sendable
                // closure is a concurrency warning.
                final class ObserverToken { var value: NSObjectProtocol? }
                let token = ObserverToken()
                token.value = NotificationCenter.default.addObserver(
                    forName: TabStripBridge.windowFullscreen, object: nil, queue: .main
                ) { [weak self] note in
                    guard (note.userInfo?[TabStripBridge.onKey] as? Bool) == true else { return }
                    if let observer = token.value { NotificationCenter.default.removeObserver(observer) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + fsDelay) {
                        self?.cmdToggleOutline()
                    }
                }
                // 2s webview-boot settle, as in the outline state.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    NotificationCenter.default.post(
                        name: TabStripBridge.debugToggleFullScreen, object: nil)
                }
            case "fstabs5":
                // Full-screen tab strip (the UIKit band, not the AppKit one):
                // five tabs, then the glue's real toggleFullScreen.
                for name in ["alpha.md", "beta.md", "gamma.tex", "delta.md"] {
                    editor.open(url: fixtures.appendingPathComponent(name))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    NotificationCenter.default.post(
                        name: TabStripBridge.debugToggleFullScreen, object: nil)
                }
            case "empty": editor.closeAllTabsForAudit()
            case "stressdoc": setSidebarVisible(true); editor.open(url: fixtures.appendingPathComponent("stress.md"))
            case "scale06", "scale25":
                Preferences.editorFontScale = state == "scale06" ? 0.6 : 2.5
                editor.setFontScale(Preferences.editorFontScale)
                editor.open(url: fixtures.appendingPathComponent("stress.md"))
            case "narrow":
                for name in ["alpha.md", "beta.md", "gamma.tex", "delta.md"] {
                    editor.open(url: fixtures.appendingPathComponent(name))
                }
                show(.primary)
                if let scene = view.window?.windowScene {
                    scene.requestGeometryUpdate(.Mac(systemFrame:
                        CGRect(x: 100, y: 100, width: 900, height: 600)))
                }
            default: break
            }
        }
    }
}
#endif
