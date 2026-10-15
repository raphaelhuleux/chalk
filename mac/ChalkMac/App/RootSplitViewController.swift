import AppKit
import WebKit
import ChalkKit
import os

/// The root's view: flipped, and reporting system appearance flips so the
/// Auto route can run the covered transition.
final class RootView: FlippedView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// The app root: a two-column layout (hideable Library sidebar + editor) under
/// one tab band that spans the window, with the floating utility pill.
///
/// Shell commands (Cmd+J sidebar, P/N/W/S, zoom, tab nav) are the main menu's
/// and route here through the responder chain. Editor keys (typing, Tab
/// tabout, hsnips, Cmd+B/I, Cmd+:) are deliberately not claimed, so they fall
/// through to the web editor.
final class RootSplitViewController: NSViewController {
    private(set) var editor = EditorContainerViewController()
    private let sidebar = SidebarViewController()

    /// This window's own folder list; the detached default keeps windows built
    /// in tests off the persisted bookmarks.
    private let locationStore: LocationStore

    // The columns. Hand-laid rather than an NSSplitView: the sidebar slide
    // translates the columns while the webview keeps its bounds, which a
    // split view's own resize animation cannot do (docs/motion.md). The
    // sidebar sits ABOVE the editor column so a sliding Library covers the
    // frozen content's overhang.
    private let sidebarColumn = FlippedView()
    private let editorColumn = FlippedView()
    private var sidebarColumnWidth: NSLayoutConstraint!
    /// The editor's leading pin: the divider while the Library is shown, the
    /// window edge while it is hidden. The column keeps its width when hidden
    /// (a zero-width column cannot satisfy the Library's own insets).
    private var editorLeadingToSidebar: NSLayoutConstraint!
    private var editorLeadingToEdge: NSLayoutConstraint!
    private(set) var isSidebarVisible = false
    /// The divider's drag handle; the width persists on release.
    private let sidebarResizeGrip = ColumnResizeGrip()
    private var sidebarDragStartWidth: CGFloat = 0

    // The sidebar slide's state (docs/motion.md "Sidebar show/hide").
    /// The column mid-slide, nil at rest.
    private var slidingSidebarColumn: NSView?
    /// Bumped by every cancel: a completion or a settle callback from an
    /// older slide must do nothing to the newer one.
    private var sidebarSlideEpoch = 0
    private var sidebarSlideSettle: WebPaintGate?
    /// True from a slide's start to its completion: the band's layout pass
    /// must not re-post the still-tiled divider mid-hide.
    private var isSidebarSliding = false
    /// Tags the one layout pass a show's placement snap runs, so the chips'
    /// inset rides the slide's clock instead of snapping.
    private var pendingStripSlideDuration: TimeInterval?

    // The tab name row. Hosted here, not in either column, so nothing moves
    // when the sidebar opens.
    private let headerBar = HeaderBarView()
    private var headerHeight: NSLayoutConstraint?
    private var headerTop: NSLayoutConstraint?

    /// The floating glass utility pill in the bottom-leading corner. It stands
    /// in every state: nothing sets `footerBar.isHidden`, only the auto-hide
    /// offset and alpha move.
    private let footerBar = FooterBarView()
    private var footerBottom: NSLayoutConstraint?

    /// Active tab id as last reported by `onTabsChanged` (nil = no tabs).
    private var currentActiveTabID: UUID?

    /// The in-flight appearance cover (docs/motion.md "Appearance"), held so a
    /// rapid theme re-toggle cancels it instead of letting an old cover fade
    /// over the newer transition's pixels.
    private var appearanceSettle: WebPaintGate?
    /// True exactly while the covered transition's own override write runs,
    /// so the root's appearance hook can tell its own echo from a genuine
    /// system appearance flip.
    private var isApplyingThemeOverride = false
    #if DEBUG
    /// Contract-test seams for the sidebar slide's settle (SidebarSlideContractTests,
    /// ZenTransitionContractTests): held for the Library's slide, which consumes them.
    var sidebarSnapshotterForTesting: WebPaintGate.Snapshotter?
    var sidebarPaintGateForTesting: WebPaintGate.PaintGate?
    /// Contract-test seams (AppearanceTransitionContractTests): force the
    /// covered path on a tabless root and make the ordering probe deterministic.
    var appearanceSnapshotterForTesting: WebPaintGate.Snapshotter?
    var appearancePaintGateForTesting: WebPaintGate.PaintGate?
    var appearanceTimingForTesting: WebPaintGate.Timing?
    /// Ordered events of the covered transition: "cover-installed",
    /// "style-applied" (preference route only), "appearance-pushed".
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
    /// chrome transitions through their Reduce Motion branches, so a test
    /// settles in two runloop turns.
    enum MotionPolicyForTesting { case system, instant }
    var motionPolicyForTesting: MotionPolicyForTesting = .system {
        didSet { editor.motionIsInstantForTesting = motionPolicyForTesting == .instant }
    }
    private var motionIsInstant: Bool { motionPolicyForTesting == .instant }
    #else
    private var motionIsInstant: Bool { false }
    #endif

    /// Whether a chrome transition animates: Reduce Motion and the `.instant`
    /// test policy both take the snap lane.
    private var motionAllowed: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !motionIsInstant
    }

    private static let log = Logger(subsystem: "com.huleux.chalk", category: "root")

    /// `locationStore` is this window's own folder list.
    init(locationStore: LocationStore = .detached(), initialContent: SceneConnectContent = .openWelcome) {
        self.locationStore = locationStore
        // Seed before anything enumerates the sample folder. Idempotent.
        let welcome = SampleContent.ensureSeeded()
        super.init(nibName: nil, bundle: nil)

        // iA-style auto-hide: the active editor's scroll offsets drive the chrome.
        editor.onActiveEditorScroll = { [weak self] y in
            self?.editorDidScroll(offset: y)
        }
        // Wire the band before the first open() so the initial tab shows up in it.
        editor.onTabsChanged = { [weak self] items in
            self?.handleTabsChanged(items)
        }
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
        // The panel's geometry changed: re-cut the band's trailing hole.
        editor.onOutlinePanelLayoutChanged = { [weak self] in
            guard let self else { return }
            self.headerBar.setOutlineHole(self.outlineHole())
        }
        editor.onShellCommand = { [weak self] name in
            // The keys the page consumes (SHELL_COMMANDS in web/src/native-host.ts)
            // come back over the transport; `save` goes to the document controller.
            switch ShellCommand(rawValue: name) {
            case .toggleOutline: self?.cmdToggleOutline()
            case .toggleOutlinePanel: self?.cmdToggleOutlinePanel()
            case .quickOpen: self?.cmdQuickOpen()
            case .save, nil: break
            }
        }
        editor.libraryRootsProvider = { [weak self] in self?.libraryRoots ?? [] }
        wireLibrary()

        // This root orchestrates the covered appearance transitions and pushes
        // the one data-theme change itself; the container's own hook stands down.
        editor.hostOwnsAppearanceTransitions = true
        ChalkAppearance.theme = Preferences.colorTheme
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

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Single sink for `editor.onTabsChanged`: redraws the band and tracks the
    /// active tab id. A tab the reader just opened, closed, or switched to
    /// must be visible; keyed on identity, not on the whole item, so typing
    /// (a dirty-marker flip) never pops the chrome back into view.
    func handleTabsChanged(_ items: [TabItem]) {
        headerBar.tabStrip.update(items)
        // The Library marks where you are, not just what exists.
        sidebar.setOpenDocument(editor.activeDocumentURL)
        let identities = items.map(\.id)
        if identities != lastTabIdentities
            || items.first(where: \.isActive)?.id != currentActiveTabID {
            lastTabIdentities = identities
            revealChrome()
        }
        currentActiveTabID = items.first(where: \.isActive)?.id
    }

    override func loadView() {
        let root = RootView()
        root.wantsLayer = true
        root.onAppearanceChange = { [weak self] in
            guard let self else { return }
            self.refreshBackground()
            // The system route: on Auto the OS flips the appearance (and the
            // native chrome) under us, so run the covered transition and let
            // the page's slower async repaint happen under a cover.
            guard self.view.appearance == nil, !self.isApplyingThemeOverride else { return }
            self.runAppearanceTransition(flippingTo: nil, preferenceRoute: false)
        }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refreshBackground()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: ChalkAppearance.themeDidChange, object: nil)

        // The columns, with the editor pinned to the sidebar's trailing edge;
        // the sidebar is added last so it stacks above the editor.
        for column in [editorColumn, sidebarColumn] {
            column.translatesAutoresizingMaskIntoConstraints = false
            column.wantsLayer = true
            view.addSubview(column)
        }
        sidebarColumn.isHidden = true
        let width = sidebarColumn.widthAnchor.constraint(equalToConstant: Preferences.sidebarWidth)
        sidebarColumnWidth = width
        editorLeadingToSidebar = editorColumn.leadingAnchor.constraint(equalTo: sidebarColumn.trailingAnchor)
        editorLeadingToEdge = editorColumn.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        addChild(editor)
        editor.view.translatesAutoresizingMaskIntoConstraints = false
        editorColumn.addSubview(editor.view)
        addChild(sidebar)
        sidebar.view.translatesAutoresizingMaskIntoConstraints = false
        sidebarColumn.addSubview(sidebar.view)
        sidebarResizeGrip.translatesAutoresizingMaskIntoConstraints = false
        sidebarResizeGrip.isHidden = true
        view.addSubview(sidebarResizeGrip)
        NSLayoutConstraint.activate([
            sidebarColumn.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarColumn.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarColumn.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            width,
            editorLeadingToEdge,
            editorColumn.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editorColumn.topAnchor.constraint(equalTo: view.topAnchor),
            editorColumn.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            editor.view.leadingAnchor.constraint(equalTo: editorColumn.leadingAnchor),
            editor.view.trailingAnchor.constraint(equalTo: editorColumn.trailingAnchor),
            editor.view.topAnchor.constraint(equalTo: editorColumn.topAnchor),
            editor.view.bottomAnchor.constraint(equalTo: editorColumn.bottomAnchor),
            sidebar.view.leadingAnchor.constraint(equalTo: sidebarColumn.leadingAnchor),
            sidebar.view.trailingAnchor.constraint(equalTo: sidebarColumn.trailingAnchor),
            sidebar.view.topAnchor.constraint(equalTo: sidebarColumn.topAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: sidebarColumn.bottomAnchor),
            sidebarResizeGrip.centerXAnchor.constraint(equalTo: sidebarColumn.trailingAnchor),
            sidebarResizeGrip.widthAnchor.constraint(equalToConstant: Self.resizeGripWidth),
            sidebarResizeGrip.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarResizeGrip.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        sidebarResizeGrip.onDragBegan = { [weak self] in
            guard let self else { return }
            self.sidebarDragStartWidth = self.sidebarColumnWidth.constant
        }
        sidebarResizeGrip.onDragged = { [weak self] travel in
            self?.resizeSidebar(to: (self?.sidebarDragStartWidth ?? 0) + travel)
        }
        sidebarResizeGrip.onDragEnded = { [weak self] in self?.persistSidebarWidth() }

        // The band, above both columns, spanning the window.
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)
        let height = headerBar.heightAnchor.constraint(equalToConstant: ChalkMetrics.tabStripHeight)
        headerHeight = height
        let top = headerBar.topAnchor.constraint(equalTo: view.topAnchor)
        headerTop = top
        NSLayoutConstraint.activate([
            top,
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            height,
        ])

        // The floating utility pill, pinned to the bottom-leading corner in
        // every state, so it holds one screen position (Y-17).
        footerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footerBar)
        let pillInset = ChalkMetrics.footerPillMargin
        let bottom = footerBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -pillInset)
        footerBottom = bottom
        NSLayoutConstraint.activate([
            footerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pillInset),
            bottom,
            footerBar.widthAnchor.constraint(equalToConstant: footerBar.pillWidth),
            footerBar.heightAnchor.constraint(equalToConstant: ChalkMetrics.footerPillHeight),
        ])

        applyBandLayout()
        // Restore a persisted zen mode's chrome state (the mode itself reaches
        // the editors via per-tab config seeding in EditorContainer).
        applyZenChrome(editingMode == .zen)
        pointerTracker.onChange = { [weak self] inside in self?.setPointerInTopBand(inside) }
        pointerTracker.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pointerTracker, positioned: .below, relativeTo: headerBar)
        NSLayoutConstraint.activate([
            pointerTracker.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pointerTracker.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pointerTracker.topAnchor.constraint(equalTo: view.topAnchor),
            pointerTracker.heightAnchor.constraint(equalTo: headerBar.heightAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyBandLayout()
    }

    private func refreshBackground() {
        // The window is one editor surface; chrome floats above it.
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.chalkEditorBackground.cgColor
        }
    }

    @objc private func themeDidChange() {
        refreshBackground()
    }

    /// The pointer resting in the band region, tracked by a transparent view
    /// under the band so a hidden band still sees the pointer reach for it.
    private let pointerTracker = PointerBandTracker()

    /// Consumed by `applyMacChromePresentation`'s band-presence write while a
    /// zen toggle is the driver, the one presence change that animates
    /// (docs/motion.md "Zen / normal"). Every other presentation pass is instant.
    private var pendingZenBandFade: TimeInterval?

    /// The titlebar's height as last read while windowed, so a window that is
    /// in full screen (where the system reserves nothing) keeps the same band.
    private var lastRealBandHeight: CGFloat = ChalkMetrics.headerHeight

    /// This window is in macOS full screen: the system titlebar is gone and
    /// the band keeps its windowed height at the screen's top edge.
    private var isMacFullscreen = false

    /// Driven by the window controller from the window's full-screen notifications.
    func setMacFullscreen(_ on: Bool) {
        guard on != isMacFullscreen else { return }
        isMacFullscreen = on
        applyMacChromePresentation()
    }

    /// The band's presence (hidden in zen) and the auto-hide re-write that
    /// follows every ownership or window-mode change, so a band hidden by
    /// scroll never carries a stale offset into its next turn.
    private func applyMacChromePresentation() {
        setBandHidden(isZen, fadeOver: pendingZenBandFade)
        applyBandLayout()
        applyChromeAutoHideState(animated: false)
    }

    /// The system titlebar's height under the content: with
    /// `fullSizeContentView` the content spans the window and the titlebar is
    /// what `contentLayoutRect` leaves out. Zero in full screen and unhosted.
    private var systemTitlebarHeight: CGFloat {
        guard let window = view.window, let content = window.contentView else { return 0 }
        return max(0, content.frame.height - window.contentLayoutRect.height)
    }

    /// The divider the chips inset to, and the column the paint is cut around,
    /// both read off the live columns.
    private func measuredBandInputs() -> BandInputs {
        guard isSidebarVisible, sidebarColumn.frame.width > 1 else { return (0, nil) }
        return (sidebarColumn.frame.maxX, sidebarColumn)
    }

    private typealias BandInputs = (dividerX: CGFloat, libraryColumn: NSView?)

    /// The spec constants `BandLayout` builds the band out of.
    private static let bandMetrics = BandLayout.Metrics(
        tabStripHeight: ChalkMetrics.tabStripHeight,
        tabStripLeading: ChalkMetrics.tabStripLeading,
        tabRowDividerGap: ChalkMetrics.tabRowDividerGap,
        editorRestingPad: ChalkMetrics.editorRestingPad)

    /// The band's one layout pass: measure the divider off the live columns,
    /// ask `BandLayout` for the numbers, write them. Every trigger goes through
    /// here so no two triggers write disagreeing subsets of the same picture.
    /// `glueAvailable: true` is the overlay-chrome branch: the editor runs
    /// full-bleed under the band and rests below web-side padding.
    private func applyBandLayout(measured: BandInputs? = nil) {
        let measured = measured ?? measuredBandInputs()
        let layout = BandLayout.resolve(
            glueAvailable: true,
            fullscreen: isMacFullscreen, zen: isZen,
            safeAreaTop: systemTitlebarHeight,
            lastRealBandHeight: lastRealBandHeight,
            dividerX: measured.dividerX, metrics: Self.bandMetrics)
        lastRealBandHeight = layout.recordedBandHeight

        if abs((headerHeight?.constant ?? -1) - layout.bandHeight) > 0.5 {
            headerHeight?.constant = layout.bandHeight
        }
        // The band never moves and its cover reaches the window's leading
        // edge; the Library is cut out of that paint rather than drawn over
        // (`libraryIsNeverPaintedOver`). Mid-slide the chips are already on
        // their way to the slide's target; a pass here must not snap them
        // back to the still-tiled divider.
        if !isSidebarSliding {
            headerBar.setStripLeadingInset(layout.chipLeadingInset, animatedOver: pendingStripSlideDuration)
        }
        headerBar.setLibraryHole(measured.libraryColumn.map { libraryHole(upTo: $0) })
        headerBar.setOutlineHole(outlineHole())
        editor.setTopClearance(layout.editorTopClearance)
        if let inset = layout.editorChromeTopInset { editor.setChromeTopInset(Double(inset)) }
    }

    /// Where the chrome that reserves space above the text ENDS, in this
    /// root's coordinates: the band's live floor while it is hosted, the
    /// system titlebar while zen hides the band, and 0 in full-screen zen.
    private var chromeReserve: CGFloat {
        guard headerBar.isHidden else { return headerBar.frame.maxY }
        return isMacFullscreen ? 0 : systemTitlebarHeight
    }

    /// Where the Library's list begins: the chrome floor.
    var libraryTreeTop: CGFloat { chromeReserve }

    /// That line in the Library's own coordinates, or nil when it has no view
    /// in a window to convert into. Its own, not the window's: a window-space
    /// line goes stale when an ancestor moves without laying the Library out
    /// again, which a column slide does.
    private func libraryTreeTopForLibrary() -> CGFloat? {
        guard sidebar.isViewLoaded, sidebar.view.window != nil else { return nil }
        return sidebar.view.convert(CGPoint(x: 0, y: libraryTreeTop), from: view).y
    }

    /// The outline panel's slice of the band, cut out of the cover: from the
    /// panel's leading edge to the band's trailing edge, the band's full
    /// height. Nil while the panel is hidden.
    private func outlineHole() -> CGRect? {
        guard editor.isViewLoaded,
              let panel = editor.outlinePanelFrame else { return nil }
        let inBand = headerBar.convert(panel, from: editor.view)
        return CGRect(x: inBand.minX,
                      y: headerBar.bounds.minY,
                      width: max(0, headerBar.bounds.maxX - inBand.minX),
                      height: headerBar.bounds.height)
    }

    /// The Library's side of the band, cut out of the cover: from the band's
    /// leading edge to the column's trailing edge, the band's full height.
    private func libraryHole(upTo column: NSView) -> CGRect {
        let columnInBand = headerBar.convert(column.bounds, from: column)
        return CGRect(x: headerBar.bounds.minX,
                      y: headerBar.bounds.minY,
                      width: max(0, columnInBand.maxX - headerBar.bounds.minX),
                      height: headerBar.bounds.height)
    }

    // MARK: - Auto-hiding chrome
    //
    // iA-style: scrolling down slides the tab band and the utility pill away;
    // scrolling back up (or reaching the document top) returns them. Zen owns
    // chrome visibility, so the policy stands down there, and
    // `Preferences.autoHideChrome` pins the chrome for readers who want it.

    /// Tab identities as of the last update, so a dirty-marker flip can be
    /// told apart from a tab opening or closing.
    private var lastTabIdentities: [UUID] = []

    private var autoHidePolicy = ChromeAutoHidePolicy()
    /// `Preferences.autoHideChrome`, cached: `applyAutoHide` runs on every
    /// scrolled frame. Refreshed by `handleAutoHidePreferenceChange`.
    private var autoHideEnabled = Preferences.autoHideChrome
    private var isChromeAutoHidden = false
    /// The pointer is resting in the top band. Reaching for a tab with the
    /// mouse must reveal it.
    private var isPointerInTopBand = false

    /// Test seam: unit tests drive `editorDidScroll` directly.
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

    /// The switch flipped in Settings. Off pins the chrome back on screen
    /// immediately rather than making the reader scroll up for it.
    @objc private func handleAutoHidePreferenceChange() {
        autoHideEnabled = Preferences.autoHideChrome
        if !autoHideEnabled { autoHidePolicy = ChromeAutoHidePolicy() }
        reapplyAutoHide()
    }

    /// Force the chrome back and restart the policy from a fresh baseline:
    /// explicit chrome interactions (sidebar toggle, zen exit) must always
    /// leave the user with visible controls.
    private func revealChrome() {
        autoHidePolicy = ChromeAutoHidePolicy()
        setChromeAutoHidden(false)
    }

    private func setChromeAutoHidden(_ hidden: Bool) {
        guard isChromeAutoHidden != hidden else { return }
        isChromeAutoHidden = hidden
        applyChromeAutoHideState()
    }

    /// Write the auto-hide state to the chrome. The band owns the tab row in
    /// every window mode here (there is no titlebar strip), so
    /// `TabChromeOwnership` reduces to "zen stands down".
    private func applyChromeAutoHideState(animated: Bool = true) {
        let hidden = isChromeAutoHidden
        let owner = TabChromeOwnership.owner(
            isMacFullScreen: isMacFullscreen, isZen: isZen, glueAvailable: false)
        let applied = TabChromeOwnership.autoHideApplication(owner: owner, autoHidden: hidden)
        let write = {
            self.applyBandHidden(applied.bandHidden)
            self.applyPillHidden(hidden)
        }
        if animated {
            animateChrome(write)
        } else {
            write()
            view.layoutSubtreeIfNeeded()
        }
    }

    private func applyBandHidden(_ hidden: Bool) {
        let shift = -(headerHeight?.constant ?? ChalkMetrics.headerHeight)
        headerTop?.constant = hidden ? shift : 0
        headerBar.alphaValue = hidden ? 0 : 1
    }

    private func applyPillHidden(_ hidden: Bool) {
        // Clear the bottom edge with slack for the pill's drop shadow.
        let shift = ChalkMetrics.footerPillHeight + ChalkMetrics.footerPillMargin + 24
        footerBottom?.constant = hidden ? shift : -ChalkMetrics.footerPillMargin
        footerBar.alphaValue = hidden ? 0 : 1
    }

    private func animateChrome(_ apply: @escaping () -> Void) {
        guard motionAllowed, view.window != nil else {
            apply()
            view.layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ChromeMotion.autoHide
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            apply()
            view.layoutSubtreeIfNeeded()
        }
    }

    private func setPointerInTopBand(_ inside: Bool) {
        guard inside != isPointerInTopBand else { return }
        isPointerInTopBand = inside
        reapplyAutoHide()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Runs every layout pass, so the chips track a live column drag.
        // Guarded writes inside, so steady passes are free.
        applyBandLayout()
    }

    /// Flush every open tab (resign-active) so no edit is lost.
    func saveAllDocuments(completion: (() -> Void)? = nil) {
        editor.saveAll(completion: completion)
    }

    /// Crash net: write recovery snapshots of every dirty buffer right now.
    func snapshotDirtyBuffers() {
        editor.snapshotDirtyBuffers()
    }

    /// Reopen buffers a crash/force-quit left behind.
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
    var stateSummary: String {
        "tabs=\(editor.openTabCount) \(editor.diagnosticSummary)"
            + " sidebar=\(isSidebarVisible) \(sidebar.diagnosticSummary)"
            + " band=\(Int(headerHeight?.constant ?? -1))"
            + " titlebar=\(Int(systemTitlebarHeight))"
            + " size=\(Int(view.bounds.width))x\(Int(view.bounds.height))"
    }

    /// Security-scoped access claimed for files opened from Finder. Held for
    /// the window's lifetime so the sandbox extension outlives the open tab.
    private var externalScopedURLs: [URL] = []

    /// Window teardown: give the claimed sandbox extensions back. Idempotent.
    func releaseExternalScopes() {
        for url in externalScopedURLs { url.stopAccessingSecurityScopedResource() }
        externalScopedURLs.removeAll()
        locationStore.releaseScopes()
    }

    deinit {
        releaseExternalScopes()
    }

    /// This window's folders that currently grant access.
    var libraryRoots: [URL] {
        locationStore.locations().filter { !$0.needsReauthorization }.map(\.url)
    }

    /// No tabs and no folders: an external folder open fills this window instead of opening another.
    var isPristine: Bool { editor.openTabCount == 0 && locationStore.locations().isEmpty }

    /// Add `url` to this window's folders and show the Library. False when it
    /// could not be stored (the user has been told).
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

    /// Open a document handed to us by the OS (Finder double-click, "Open With").
    func openExternalDocument(_ url: URL) {
        if url.startAccessingSecurityScopedResource() {
            externalScopedURLs.append(url)
        }
        editor.open(url: url, reuseCurrentIfClean: true)
    }

    // MARK: - Window restoration

    var openTabCount: Int { editor.openTabCount }

    /// Snapshot this window's restorable state (open file tabs, active tab,
    /// sidebar visibility, outline panel).
    func captureSession() -> WindowSession {
        let snapshot = editor.sessionSnapshot()
        let records = snapshot.urls.map {
            // A bookmark per tab: it makes restoration independent of
            // Location-resolution order, and it is the only thing that reopens
            // an external file's sandbox scope after relaunch.
            WindowSession.TabRecord(path: $0.path, bookmark: FileBookmark.make(for: $0))
        }
        return WindowSession(
            tabs: records, activeIndex: snapshot.activeIndex,
            isSidebarVisible: isSidebarVisible,
            isOutlineVisible: editor.isOutlinePanelVisible)
    }

    /// Reopen a restored window's tabs. Unresolvable or unreadable files (moved
    /// or deleted between quit and relaunch) are dropped silently.
    private func applyRestoredSession(_ session: WindowSession) {
        var openedRecordIndices: [Int] = []
        for (index, record) in session.tabs.enumerated() {
            let url = record.bookmark.flatMap(FileBookmark.resolve)
                ?? URL(fileURLWithPath: record.path)
            // Enter the scope before the readability check: outside it, a
            // sandboxed file isn't readable at all. Held for the session.
            let accessing = url.startAccessingSecurityScopedResource()
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                if accessing { url.stopAccessingSecurityScopedResource() }
                continue
            }
            if accessing { externalScopedURLs.append(url) }
            // activating: false: bulk restore must not boot one webview per tab;
            // only the final activate below boots one.
            editor.open(url: url, activating: false)
            openedRecordIndices.append(index)
        }
        if let wanted = session.activeIndex,
           let position = openedRecordIndices.firstIndex(of: wanted) {
            editor.activateTab(at: position)
        } else if !openedRecordIndices.isEmpty {
            editor.activateTab(at: 0)
        }
        if session.isSidebarVisible {
            setSidebarVisible(true)
        }
        if session.isOutlineVisible {
            editor.setOutlinePanelVisible(true, animated: false)
        }
    }

    // MARK: - Shell commands
    // Surfaced as the menu bar; they route here through the responder chain.

    /// Apply the stored editor font scale to this window's tabs.
    func applyEditorFontScale() { editor.setFontScale(Preferences.editorFontScale) }
    func applyEditorMeasure() { editor.setMeasure(Preferences.editorMeasure) }
    func applyEditorLineHeight() { editor.setLineHeight(Preferences.editorLineHeight) }
    func applyTextAlignment() { editor.setTextAlign(Preferences.textAlignment) }

    /// Push the shell-owned editor config (editing mode, default view mode) to
    /// this window's tabs, with this window's own `editingMode`.
    func applyEditorConfig() { editor.applyEditorConfig() }

    /// Change the DEFAULT view mode: persist it and push it to every tab of
    /// every window (one process-wide preference).
    func setViewModeDefault(_ mode: ViewMode) {
        Preferences.viewMode = mode
        for root in liveRootsIncludingSelf() { root.applyEditorConfig() }
    }

    @objc func cmdViewModePreview(_ sender: Any?) { setViewModeDefault(.preview) }
    @objc func cmdViewModeMixed(_ sender: Any?) { setViewModeDefault(.mixed) }
    @objc func cmdViewModeSource(_ sender: Any?) { setViewModeDefault(.source) }

    /// Push the heading palette (or the empty payload that clears it).
    func applyHeadingColors() { editor.applyHeadingColors() }

    /// Push already-composed hsnips to this window's tabs.
    func pushHsnips(_ content: String) { editor.setHsnips(content) }

    /// `everyLiveRoot()`, plus this root when it is not in a window yet: the
    /// window a change came from always applies it.
    private func liveRootsIncludingSelf() -> [RootSplitViewController] {
        let roots = Self.everyLiveRoot()
        return roots.contains { $0 === self } ? roots : roots + [self]
    }

    /// Every live window's root controller, for process-wide settings that
    /// must reach more than the window they were changed from.
    static func everyLiveRoot() -> [RootSplitViewController] {
        NSApp.windows.compactMap { $0.contentViewController as? RootSplitViewController }
    }

    // MARK: - The Library column

    /// Wire the Library's callbacks and the cross-window signals.
    private func wireLibrary() {
        sidebar.locationsProvider = { [weak self] in self?.locationStore.locations() ?? [] }
        // The Library's list starts on the chrome floor: it asks, every
        // layout pass, and the host answers from its own live chrome.
        sidebar.treeTopProvider = { [weak self] in self?.libraryTreeTopForLibrary() }
        // Browse-reuse: a sidebar click replaces the current tab when it's
        // unmodified, so browsing files doesn't spawn tabs.
        sidebar.onOpenFile = { [weak self] url in self?.openFromLibrary(url) }
        // Asset rows (image/PDF) never reach the editor: a preview instead.
        sidebar.onPreviewFile = { [weak self] url in self?.previewAsset(url) }
        // "Open in New Tab": the browse-reuse that makes clicking through the
        // tree cheap is exactly what this menu item opts out of.
        sidebar.onOpenFileInNewTab = { [weak self] url in self?.openFromLibrary(url, inNewTab: true) }
        sidebar.onOpenFileInNewWindow = { url in
            (NSApp.delegate as? AppDelegate)?.openNewWindow(initialContent: .openEmpty)
                .root.openExternalDocument(url)
        }
        sidebar.onAddLocation = { [weak self] url in self?.addFolderToWindow(url) }
        // A Location whose sandbox bookmark stopped granting access heals in
        // place when the user re-picks its folder ("Grant Access…"). The store
        // broadcasts `.chalkLibraryDidChange`, which reloads every window's
        // sidebar, including this one, so no local reload here.
        sidebar.onReauthorizeLocation = { [weak self] id, url in
            self?.locationStore.reauthorize(id: id, with: url)
        }
        // "Remove from Window" drops the Location's security-scoped bookmark
        // and refreshes the tree. Open tabs from that Location stay open.
        sidebar.onRemoveLocation = { [weak self] id in self?.locationStore.remove(id: id) }
        // A file created from a sidebar context menu opens in a tab.
        sidebar.onOpenCreatedFile = { [weak self] url in self?.editor.open(url: url) }
        // A draft (Cmd+N) saved to a location for the first time: surface the
        // new file in every window's tree, not just this one's.
        editor.onDraftSaved = { _ in
            NotificationCenter.default.post(name: .chalkLibraryDidChange, object: nil)
        }
        // A rename or drag-move remaps any open tab under the moved path
        // (keeping unsaved edits) rather than closing it. Broadcast so every
        // window remaps: a rename in window A must not leave window B's tab
        // saving to the dead path.
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

    /// The one fork every Library open path runs through (sidebar click, row
    /// menu, Quick Open). The tree lists documents AND the images/PDFs those
    /// documents embed, and only documents can become a tab: handing a png to
    /// `editor.open` would decode its bytes as Markdown, so assets divert to
    /// the preview. `inNewTab` is a document-only distinction (browse-reuse vs
    /// always-a-fresh-tab); a preview has no tab to reuse.
    func openFromLibrary(_ url: URL, inNewTab: Bool = false) {
        if FileTree.kind(of: url) == .asset {
            previewAsset(url)
        } else {
            editor.open(url: url, reuseCurrentIfClean: !inNewTab)
        }
    }

    /// The preview sheet arrives with phase 4 of the plan; the routing fact is
    /// recorded now so no asset can reach a tab.
    private func previewAsset(_ url: URL) {
        lastPreviewedAsset = url
        Self.log.notice("asset preview is not in this build yet")
    }

    /// Last URL routed to the preview (AssetPreviewRoutingTests).
    private(set) var lastPreviewedAsset: URL?

    /// Reveal or hide the Library column: the placement both lanes land on.
    func setSidebarVisible(_ visible: Bool) {
        guard visible != isSidebarVisible else { return }
        isSidebarVisible = visible
        sidebarColumn.isHidden = !visible
        sidebarResizeGrip.isHidden = !visible
        if visible { sidebarColumnWidth.constant = Preferences.sidebarWidth }
        // Deactivate before activating, so no pass sees both pins.
        (visible ? editorLeadingToEdge : editorLeadingToSidebar)?.isActive = false
        (visible ? editorLeadingToSidebar : editorLeadingToEdge)?.isActive = true
        if isViewLoaded { view.layoutSubtreeIfNeeded() }
    }

    /// The grip's drag: live, clamped to the resizable range.
    private func resizeSidebar(to width: CGFloat) {
        let range = Preferences.sidebarWidthRange
        let wanted = min(max(width, range.lowerBound), range.upperBound)
        guard abs(sidebarColumnWidth.constant - wanted) > 0.5 else { return }
        sidebarColumnWidth.constant = wanted
        view.layoutSubtreeIfNeeded()
    }

    /// Persist the dragged width, only on a real change, so a steady pass
    /// never churns UserDefaults. 2.0 is a rounding guard; a drag moves many points.
    private func persistSidebarWidth() {
        let width = sidebarColumnWidth.constant
        guard isSidebarVisible, Preferences.sidebarWidthRange.contains(width),
              abs(Preferences.sidebarWidth - width) > 2.0 else { return }
        Preferences.sidebarWidth = width
    }

    static let resizeGripWidth: CGFloat = 8

    /// Run a Library show/hide with a short slide; Reduce Motion snaps instantly.
    ///
    /// The editor is a WKWebView, which paints asynchronously in the
    /// web-content process, so any bounds change near the animation flashes
    /// stale tiles at the wrong layout. The visible slide therefore never
    /// touches the webview's bounds: the width is frozen at its current value
    /// and the content is translated instead (`contentShift`). The one real
    /// reflow runs after the slide, while everything is stationary, under a
    /// `takeSnapshot` image of the settled content (`settleSidebarSlide`).
    private func animateSidebar(show: Bool) {
        // Zen owns the chrome: panels do not open into it, whichever lane
        // asked (Cmd+J, the pill, a test step). The way out is leaving zen.
        // `UIState.applying` encodes the same refusal.
        if show, isZen { return }
        // One code path (docs/motion.md "Sidebar show/hide"): a dead
        // snapshotter degrades to a covered reflow on the backstop clock
        // (WebPaintGate), never a stuck width. A rapid re-toggle lands
        // mid-slide: finish the previous transition's bookkeeping first.
        cancelSidebarSlide()
        guard motionAllowed, view.window != nil else {
            setSidebarVisible(show)
            return
        }
        if show { animateSidebarIn() } else { animateSidebarOut() }
    }

    /// The placement snaps at slide start (its layout pass posts the chips'
    /// new inset on the slide's clock); the column starts a width off screen
    /// and slides in while the frozen editor content slides by `contentShift`.
    private func animateSidebarIn() {
        editor.freezeContentWidth()
        pendingStripSlideDuration = ChalkMetrics.motionSidebar
        setSidebarVisible(true)
        pendingStripSlideDuration = nil
        let width = sidebarColumn.frame.width
        let shift = contentShift(sidebarWidth: width, showing: true)
        // The frozen full-width content overhangs the (now narrower) column's
        // leading edge; it stays visible there until the sidebar covers it.
        editor.view.clipsToBounds = false
        slidingSidebarColumn = sidebarColumn
        isSidebarSliding = true
        let epoch = sidebarSlideEpoch
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            // A re-toggle canceled this slide; its bookkeeping is done and
            // running the settle here would unfreeze mid-NEW-slide.
            guard let self, epoch == self.sidebarSlideEpoch else { return }
            self.slidingSidebarColumn = nil
            self.isSidebarSliding = false
            self.editor.view.clipsToBounds = true
            self.applyBandLayout() // anything the slide guard held back
            self.settleSidebarSlide()
        }
        sidebarColumn.layer?.transform = CATransform3DMakeTranslation(-width, 0, 0)
        sidebarColumn.layer?.chalkSlide(toTranslationX: 0, over: ChalkMetrics.motionSidebar)
        editor.slideContent(by: shift, over: ChalkMetrics.motionSidebar)
        CATransaction.commit()
    }

    /// How far the visible text travels when the editor column resizes by one
    /// sidebar width. The web content column is `Preferences.editorMeasure`
    /// wide (the CSS px the host pushes into the page), centered while the
    /// editor is wider than that and edge-anchored below the cap. So the
    /// travel is the leading-edge move plus the inset change: Δ/2 when fully
    /// wide, the full sidebar width when fully narrow, in between when the
    /// toggle crosses the cap.
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

    /// Mirror of `animateSidebarIn`, with the placement at the END: the real
    /// column slides out first and the hide lands in the completion, where
    /// the frozen content's screen rect is identical across the snap.
    private func animateSidebarOut() {
        let width = sidebarColumn.frame.width
        let shift = contentShift(sidebarWidth: width, showing: false)
        editor.freezeContentWidth()
        // The chips ride the column's clock: the placement lands only in the
        // completion, so post the target inset now; the slide guard keeps the
        // layout passes in between from re-measuring the still-tiled divider.
        isSidebarSliding = true
        headerBar.setStripLeadingInset(0, animatedOver: ChalkMetrics.motionSidebar)
        // The content's visual rect crosses the column's leading edge on its
        // way out; the departing sidebar (stacked above) covers the seam.
        editor.view.clipsToBounds = false
        slidingSidebarColumn = sidebarColumn
        let epoch = sidebarSlideEpoch
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, epoch == self.sidebarSlideEpoch else { return }
            self.slidingSidebarColumn = nil
            self.isSidebarSliding = false
            self.editor.view.clipsToBounds = true
            self.setSidebarVisible(false)
            self.sidebarColumn.layer?.chalkEndSlide()
            self.applyBandLayout() // after the snap: the divider is final
            self.settleSidebarSlide()
        }
        sidebarColumn.layer?.chalkSlide(toTranslationX: -width, over: ChalkMetrics.motionSidebar)
        editor.slideContent(by: shift, over: ChalkMetrics.motionSidebar)
        CATransaction.commit()
    }

    /// Abort any in-flight slide so a new one starts from consistent state.
    /// The epoch bump turns the canceled animation's completion into a no-op
    /// and `cancel()` does the same for the settle's pending callbacks: a
    /// stale snapshot or backstop must never act on the next slide's state.
    private func cancelSidebarSlide() {
        sidebarSlideEpoch += 1
        sidebarSlideSettle?.cancel()
        sidebarSlideSettle = nil
        slidingSidebarColumn?.layer?.chalkEndSlide()
        slidingSidebarColumn = nil
        isSidebarSliding = false
        if editor.isViewLoaded { editor.view.clipsToBounds = true }
        editor.unfreezeContentWidth()
    }

    /// Post-slide settle: swap the frozen, translated webview for its real
    /// layout in one stationary reflow, masked by an opaque cover carrying a
    /// bitmap of the pixels on screen. `WebPaintGate` owns the ordering and
    /// the guaranteed release (docs/motion.md "Sidebar show/hide"): the
    /// release is armed before the snapshot is requested, so a snapshot that
    /// never lands degrades to a covered reflow on the backstop clock, never
    /// a stuck width or a naked reflow. The shield is `makeWebCover`.
    private func settleSidebarSlide() {
        guard editor.isViewLoaded, let seams = coverSeams(for: .sidebarSlide) else {
            // No webview to mask (no open tab): nothing can flicker; release now.
            editor.unfreezeContentWidth()
            return
        }
        let editorView = editor.view
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

    @objc func cmdToggleSidebar(_ sender: Any? = nil) {
        // An explicit chrome interaction always brings the chrome back.
        revealChrome()
        animateSidebar(show: !isSidebarVisible)
    }

    @objc func cmdQuickOpen(_ sender: Any? = nil) {
        Self.log.notice("Quick Open is not in this build yet")
    }

    @objc func cmdToggleOutline(_ sender: Any? = nil) {
        Self.log.notice("the outline palette is not in this build yet")
    }

    /// ⌘K: the persistent outline panel. Zen owns the chrome: opening into it
    /// is refused, like the Library.
    @objc func cmdToggleOutlinePanel(_ sender: Any? = nil) {
        let show = !editor.isOutlinePanelVisible
        if show, isZen { return }
        revealChrome()
        editor.setOutlinePanelVisible(show, animated: motionAllowed)
    }

    @objc func cmdReportProblem(_ sender: Any? = nil) {
        Self.log.notice("Report a Problem is not in this build yet")
    }

    @objc func cmdPrivacy(_ sender: Any? = nil) {
        Self.log.notice("Privacy is not in this build yet")
    }

    @objc func cmdNewFile(_ sender: Any? = nil) {
        editor.newFile()
    }

    @objc func cmdSave(_ sender: Any? = nil) {
        editor.save()
    }

    @objc func cmdCloseTab(_ sender: Any? = nil) {
        if editor.hasOpenTabs {
            editor.closeActiveTab()
            return
        }
        // Empty window: Cmd+W closes the window itself, Mac-style.
        view.window?.performClose(nil)
    }

    @objc func cmdZoomIn(_ sender: Any? = nil) { setZoom(Preferences.editorFontScale + 0.1) }
    @objc func cmdZoomOut(_ sender: Any? = nil) { setZoom(Preferences.editorFontScale - 0.1) }
    @objc func cmdZoomReset(_ sender: Any? = nil) { setZoom(1.0) }

    /// Zoom is one process-wide preference, so every window follows.
    private func setZoom(_ scale: Double) {
        Preferences.editorFontScale = scale // clamps
        for root in liveRootsIncludingSelf() { root.applyEditorFontScale() }
    }

    @objc func cmdNextTab(_ sender: Any? = nil) { editor.nextTab() }
    @objc func cmdPrevTab(_ sender: Any? = nil) { editor.previousTab() }

    @objc func cmdSettings(_ sender: Any? = nil) {
        Self.log.notice("Settings is not in this build yet")
    }

    @objc func cmdAddLocation(_ sender: Any? = nil) {
        sidebar.presentAddLocationPicker()
    }

    // MARK: - Editing modes

    @objc func cmdCycleEditingMode(_ sender: Any? = nil) { setEditingMode(editingMode.next) }
    @objc func cmdEditingModeNormal(_ sender: Any? = nil) { setEditingMode(.normal) }
    @objc func cmdEditingModeZen(_ sender: Any? = nil) { setEditingMode(.zen) }
    @objc func cmdEditingModeTypewriter(_ sender: Any? = nil) { setEditingMode(.typewriter) }
    @objc func cmdEditingModeFocus(_ sender: Any? = nil) { setEditingMode(.focus) }

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
    /// docs/motion.md "Zen / normal": the band fades over `motionStandard`,
    /// the Library leaves through the sidebar slide, and the web-side resting
    /// offset glides by FLIP. Reduce Motion and `.instant` snap; every lane
    /// lands the same final state.
    private func applyZenChrome(_ on: Bool) {
        guard isZen != on else { return }
        isZen = on
        // Zen owns chrome visibility; leave the auto-hide offsets neutral in
        // both directions so entering/leaving zen starts from chrome shown.
        revealChrome()
        let animated = motionAllowed
        let fade: TimeInterval? = animated ? ChalkMetrics.motionStandard : nil
        // The resting-offset change glides web-side on zen's clock: armed
        // before anything can lay the band out (the Library and panel closes
        // below run a layout pass), cleared after, so only this toggle's real
        // change consumes it.
        editor.nextChromeTopGlideDuration = fade
        if on, isSidebarVisible {
            animateSidebar(show: false)
        }
        if on, editor.isOutlinePanelVisible {
            editor.setOutlinePanelVisible(false, animated: animated)
        }
        // The presentation pass applies the band's presence and the editor's
        // resting metrics. `pendingZenBandFade` is the one lane that animates a
        // presence change.
        pendingZenBandFade = fade
        applyMacChromePresentation()
        pendingZenBandFade = nil
        editor.nextChromeTopGlideDuration = nil
        if !animated, isViewLoaded { view.layoutSubtreeIfNeeded() }
    }

    /// In-flight zen band fade generation: an instant presence write (or a
    /// newer fade) must turn a stale fade-out completion into a no-op.
    private var zenBandFadeEpoch = 0

    /// The band's one presence seam: zen fades it over `fadeOver`
    /// (docs/motion.md "Zen / normal"); every other caller passes nil and gets
    /// an instant write. Both lanes land the same final state (`isHidden`
    /// set, alpha 1).
    private func setBandHidden(_ hidden: Bool, fadeOver duration: TimeInterval?) {
        guard headerBar.isHidden != hidden else { return }
        zenBandFadeEpoch += 1
        guard let duration, duration > 0, headerBar.window != nil else {
            headerBar.isHidden = hidden
            headerBar.alphaValue = 1
            return
        }
        let epoch = zenBandFadeEpoch
        if hidden {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                headerBar.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, epoch == self.zenBandFadeEpoch else { return }
                self.headerBar.isHidden = true
                self.headerBar.alphaValue = 1
            })
        } else {
            headerBar.isHidden = false
            headerBar.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                headerBar.animator().alphaValue = 1
            }
        }
    }

    // MARK: - Settings / appearance

    func applyThemePreference() {
        let wanted = Preferences.themePreference.appearance
        guard view.appearance?.name != wanted?.name
            || ChalkAppearance.theme != Preferences.colorTheme else {
            // Same override and theme (the Settings broadcast re-applies on
            // every general change): nothing flips, so nothing to cover.
            return
        }
        runAppearanceTransition(flippingTo: wanted, preferenceRoute: true)
    }

    /// docs/motion.md "Appearance": a theme change is a covered transition.
    /// Snapshot the active surface (old colours) → opaque cover over the
    /// webview's rect → in one turn: the appearance flip, the `data-theme`
    /// push, and a dissolve on the band and pill (never the root view: its
    /// transition snapshot would include the webview's remote layer) → the
    /// in-page paint gate → cover fade (`motionFast`).
    ///
    /// `preferenceRoute` flips the override inside the covered turn. The
    /// system route (Auto) is the OS having already flipped the appearance and
    /// the native chrome, so the cover owns only the page's async repaint.
    ///
    /// Reduce Motion (and `.instant`) keep the cover with zero-duration fades:
    /// the mismatch flash it prevents is correctness, not motion.
    private func runAppearanceTransition(flippingTo style: NSAppearance?, preferenceRoute: Bool) {
        let animated = motionAllowed
        appearanceSettle?.cancel()
        appearanceSettle = nil

        let flip: () -> Void = { [weak self] in
            guard let self else { return }
            if animated, self.view.window != nil {
                for chrome in [self.headerBar, self.footerBar] as [NSView] {
                    let dissolve = CATransition()
                    dissolve.type = .fade
                    dissolve.duration = ChalkMetrics.motionStandard
                    chrome.layer?.add(dissolve, forKey: "appearance")
                }
            }
            if preferenceRoute {
                self.isApplyingThemeOverride = true
                self.view.appearance = style
                ChalkAppearance.theme = Preferences.colorTheme
                // The hook may fire a turn later; keep the echo guard up past this turn.
                DispatchQueue.main.async { [weak self] in self?.isApplyingThemeOverride = false }
                #if DEBUG
                self.appearanceTransitionTrailForTesting.append("style-applied")
                #endif
            }
            let dark = style?.isChalkDark ?? self.view.effectiveAppearance.isChalkDark
            self.editor.pushAppearance(dark: dark, theme: Preferences.colorTheme)
            #if DEBUG
            self.appearanceTransitionTrailForTesting.append("appearance-pushed")
            #endif
        }

        guard let seams = coverSeams(for: .appearance), editor.isViewLoaded, editor.view.window != nil else {
            // No surface to mask (no open tab, or not hosted yet): nothing can tear.
            flip()
            return
        }

        var timing = WebPaintGate.Timing()
        if !animated { timing.fade = 0 }
        #if DEBUG
        if let injected = appearanceTimingForTesting { timing = injected }
        #endif
        let editorView = editor.view
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

    /// Which covered transition is asking for seams, so a DEBUG build can
    /// hand back that transition's injected test doubles.
    private enum CoveredTransition { case sidebarSlide, appearance }

    /// The seams a covered transition runs on: the live surface's, replaced in
    /// DEBUG by the transition's injected test doubles (no bitmap source
    /// then). nil when there is nothing to mask.
    private func coverSeams(for transition: CoveredTransition)
        -> (snapshotter: WebPaintGate.Snapshotter, paintGate: WebPaintGate.PaintGate, bitmapSource: NSView?)? {
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
        return liveWebPaintSeams().map { ($0.snapshotter, $0.paintGate, $0.bitmapSource) }
    }

    /// The live editor surface's covered-transition seams: a bitmap of the
    /// pixels on screen, and a gate that answers once the web process has
    /// painted the new layout (two rAFs, not a delay: a fixed delay races the
    /// async repaint and loses on heavy documents).
    private func liveWebPaintSeams() -> (snapshotter: WebPaintGate.Snapshotter,
                                         paintGate: WebPaintGate.PaintGate,
                                         bitmapSource: NSView)? {
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

    /// The opaque shield a covered transition installs over the editor: the
    /// webview's whole rect in the editor background, with the bitmap at its
    /// old offset. It masks pixels and never gates input.
    private func makeWebCover(over editorView: NSView,
                              bitmap image: NSImage?, of bitmapSource: NSView?) -> NSView? {
        guard editorView.window != nil else { return nil }
        let cover = PassthroughView()
        cover.wantsLayer = true
        editorView.effectiveAppearance.performAsCurrentDrawingAppearance {
            cover.layer?.backgroundColor = NSColor.chalkEditorBackground.cgColor
        }
        cover.clipsToBounds = true
        var finalRect = editorView.bounds
        finalRect.origin.y = editor.topClearance
        finalRect.size.height -= editor.topClearance
        cover.frame = finalRect
        if let image, let bitmapSource {
            let bitmap = NSImageView(image: image)
            bitmap.imageScaling = .scaleAxesIndependently
            bitmap.frame = editorView
                .convert(bitmapSource.bounds, from: bitmapSource)
                .offsetBy(dx: -finalRect.origin.x, dy: -finalRect.origin.y)
            cover.addSubview(bitmap)
        }
        editorView.addSubview(cover)
        return cover
    }

    /// Give the editor focus back after a sheet or overlay goes away.
    private func returnFocusAfterDismiss() {
        editor.focusActiveSurface()
    }
}

/// Pointer tracking over the band's region. A view under the band, not the
/// band itself: a hidden (slid-out) band has no tracking area to see the
/// pointer come back for it.
final class PointerBandTracker: FlippedView {
    var onChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onChange?(true) }
    override func mouseExited(with event: NSEvent) { onChange?(false) }
}

/// A view that masks pixels and takes no clicks.
final class PassthroughView: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension RootSplitViewController: NSMenuItemValidation {
    /// Checkmark the active mode in the View → Editing Mode menu, and the
    /// default view mode.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let action = item.action, let mode = Self.editingModeByAction[action] {
            item.state = mode == editingMode ? .on : .off
        }
        if let action = item.action, let mode = Self.viewModeByAction[action] {
            item.state = mode == Preferences.viewMode ? .on : .off
        }
        return true
    }

    private static let editingModeByAction: [Selector: EditingMode] = [
        #selector(cmdEditingModeNormal(_:)): .normal,
        #selector(cmdEditingModeZen(_:)): .zen,
        #selector(cmdEditingModeTypewriter(_:)): .typewriter,
        #selector(cmdEditingModeFocus(_:)): .focus,
    ]

    private static let viewModeByAction: [Selector: ViewMode] = [
        #selector(cmdViewModePreview(_:)): .preview,
        #selector(cmdViewModeMixed(_:)): .mixed,
        #selector(cmdViewModeSource(_:)): .source,
    ]
}

#if DEBUG
extension RootSplitViewController {
    /// Test hooks (ChalkMacTests): zen chrome state, without exposing the views.
    var isHeaderHiddenForTesting: Bool { headerBar.isHidden }
    var headerBandHeightForTesting: CGFloat { headerHeight?.constant ?? -1 }
    /// Utility-pill placement, in root-view coords.
    var footerPillFrameForTesting: CGRect { footerBar.frame }
    /// What the pill's editing-mode menu would check right now.
    var pillEditingModeForTesting: EditingMode? { footerBar.currentEditingMode?() }
    var editorChromeTopInsetForTesting: Double { editor.chromeTopInsetForTesting }
    var editorMeasureForTesting: Double? { editor.lastPushedMeasure }
    var editorLineHeightForTesting: Double? { editor.lastPushedLineHeight }
    var editorTextAlignForTesting: String? { editor.lastPushedTextAlign?.cssValue }
    var editorForTesting: EditorContainerViewController { editor }
    var isOutlinePanelVisibleForTesting: Bool { editor.isOutlinePanelVisible }
    /// The band's trailing cut-out in root coordinates, nil when none.
    var bandTrailingHoleForTesting: CGRect? {
        headerBar.paintTrailingHoleForTesting.map { view.convert($0, from: headerBar) }
    }
    func setOutlinePanelForTesting(_ visible: Bool) { editor.setOutlinePanelVisible(visible, animated: false) }
    /// Drive the web-forwarded shell command lane (`editor.onShellCommand`).
    func simulateShellCommandForTesting(_ name: String) { editor.onShellCommand?(name) }
    /// Drives the real `onTabsChanged` sink with a canned strip.
    func simulateTabsChangedForTesting(_ items: [TabItem]) { handleTabsChanged(items) }

    /// Drives the full-screen chrome switch that nothing else in a test can
    /// reach: the same flag and presentation path the window's notification
    /// drives, without making the window full screen (nothing in-process can).
    func setMacFullscreenForTesting(_ on: Bool) {
        guard isMacFullscreen != on else { return }
        isMacFullscreen = on
        applyMacChromePresentation()
        view.layoutSubtreeIfNeeded()
    }

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
        let hole = headerBar.isHidden
            ? nil
            : headerBar.paintHoleForTesting.map { view.convert($0, from: headerBar) }
        let trailingHole = headerBar.isHidden
            ? nil
            : headerBar.paintTrailingHoleForTesting.map { view.convert($0, from: headerBar) }
        let tabStripFrame = headerBar.isHidden
            ? CGRect.zero
            : view.convert(headerBar.tabStrip.frame, from: headerBar)
        let panel: CGRect? = {
            guard isSidebarVisible, sidebar.isViewLoaded else { return nil }
            return view.convert(sidebar.panelFrameForTesting, from: sidebar.view)
        }()
        let firstRowTop: CGFloat? = panel == nil ? nil
            : sidebar.firstRowFrameForTesting.map { view.convert($0, from: sidebar.view).minY }
        let firstHeaderTop: CGFloat? = panel == nil ? nil
            : sidebar.firstHeaderFrameForTesting.map { view.convert($0, from: sidebar.view).minY }
        let scrollOffset: CGFloat? = panel == nil ? nil : sidebar.libraryScrollOffsetForTesting
        let activeChip: CGRect? = headerBar.isHidden
            ? nil
            : headerBar.tabStrip.activeTabFrameForTesting
                .map { view.convert($0, from: headerBar.tabStrip) }
        let pill = footerBar.isHidden ? CGRect.zero : footerBar.frame
        let pillCorner = CGPoint(x: ChalkMetrics.footerPillMargin,
                                 y: ChalkMetrics.footerPillMargin)
        let editorContent: CGRect = editor.isViewLoaded
            ? view.convert(editor.contentViewFrameForTesting, from: editor.view) : .zero
        let activeLabel: CGRect? = headerBar.isHidden
            ? nil
            : headerBar.tabStrip.activeLabelFrameForTesting
                .map { view.convert($0, from: headerBar.tabStrip) }
        let activeUnderline: CGRect? = headerBar.isHidden
            ? nil
            : headerBar.tabStrip.activeUnderlineFrameForTesting
                .map { view.convert($0, from: headerBar.tabStrip) }
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
            reserveTop: chromeReserve,
            safeLeading: 0,
            libraryFirstRowTop: firstRowTop,
            libraryFirstHeaderTop: firstHeaderTop,
            libraryScrollOffset: scrollOffset,
            activeChip: activeChip,
            activeTabLabel: activeLabel,
            activeTabUnderline: activeUnderline,
            macStrip: nil,
            outlinePanel: editor.isViewLoaded
                ? editor.outlinePanelFrame.map { view.convert($0, from: editor.view) } : nil,
            outlinePanelIsOverlay: editor.outlinePanelIsOverlay,
            outlinePanelPushMinimum: ChalkMetrics.outlinePanelPushMinimumEditorWidth,
            bandPaintTrailingHole: trailingHole)
    }

    /// Drive one user-level chrome toggle through the REAL entry points.
    func applyTransitionForTesting(_ step: TransitionStep) {
        switch step {
        case .sidebar(let visible):
            guard visible != isSidebarVisible else { return }
            revealChrome()
            animateSidebar(show: visible)
        case .window(let mode):
            setMacFullscreenForTesting(mode == .fullscreen)
        case .zen(let on):
            setEditingMode(on ? .zen : .normal)
        case .outline(let visible):
            guard visible != editor.isOutlinePanelVisible else { return }
            if visible, isZen { return }
            revealChrome()
            editor.setOutlinePanelVisible(visible, animated: false)
        }
    }

    /// Where the chrome that reserves space above the text ENDS.
    var chromeReserveForTesting: CGFloat { chromeReserve }

    /// Whether the sidebar slide still owns any state (a sliding column or a
    /// live settle). True mid-flight; false at rest.
    var isSidebarTransitionInFlightForTesting: Bool {
        slidingSidebarColumn != nil || (sidebarSlideSettle?.isActive ?? false)
    }

    /// The Library itself, for the tests that drive its own seams.
    var sidebarForTesting: SidebarViewController { sidebar }
    /// The view the slide transforms; the editor must never be inside it.
    var sidebarColumnForTesting: NSView { sidebarColumn }
    var headerBarForTesting: NSView { headerBar }
    var sidebarResizeGripFrameForTesting: CGRect { sidebarResizeGrip.frame }
    var sidebarResizeGripIsHiddenForTesting: Bool { sidebarResizeGrip.isHidden }
    /// The chips' inset past the traffic lights, as last written.
    var stripLeadingInsetForTesting: CGFloat { headerBar.stripLeadingInsetForTesting }
    var lastPreviewedAssetForTesting: URL? { lastPreviewedAsset }

    /// The Library list's scroll offset (see the sidebar seams).
    var libraryScrollOffsetForTesting: CGFloat { sidebar.libraryScrollOffsetForTesting }
    func setLibraryScrollOffsetForTesting(_ offset: CGFloat) {
        sidebar.setLibraryScrollOffsetForTesting(offset)
    }

    /// Point the Library at the given folders without touching the real
    /// `LocationStore`, whose security-scoped bookmarks a test must never write.
    func setLibraryLocationsForTesting(_ urls: [URL]) {
        sidebar.locationsProvider = {
            urls.map { Location(id: $0.lastPathComponent, name: $0.lastPathComponent, url: $0) }
        }
        sidebar.reload()
    }

    /// Drive the divider drag the grip would.
    func resizeSidebarForTesting(to width: CGFloat) {
        resizeSidebar(to: width)
        persistSidebarWidth()
    }
}
#endif
