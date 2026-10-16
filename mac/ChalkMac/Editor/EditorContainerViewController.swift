import AppKit
import WebKit
import ChalkKit
import os

/// File names are personal data, so they interpolate as `.private`.
private let containerLog = Logger(subsystem: "com.huleux.chalk", category: "editor-container")

/// The container's root view: flipped, clipping, and reporting appearance
/// flips to the controller.
final class EditorContainerView: FlippedView {
    var onAppearanceChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: ChalkAppearance.themeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    @objc private func themeDidChange() { onAppearanceChange?() }
}

/// Hosts the open tabs and shows the active tab's editor surface. Each tab owns its surface and
/// document controller, so switching tabs preserves cursor, scroll and undo.
final class EditorContainerViewController: NSViewController {
    private var tabs: [Tab] = []
    private var activeTab: Tab?

    /// Reads the host window's own editing mode. A closure, not a stored copy: a copy goes stale
    /// when another window changes its mode. The default serves a container with no host (tests).
    var currentEditingMode: () -> EditingMode = { Preferences.editingMode }

    private let contentView = FlippedView()
    /// "No document open". Visibility is set explicitly by `refreshEmptyState()`, never by
    /// occlusion: a detached surface must not read as an empty window under a live chip.
    /// See docs/issues/2026-07-24-blank-editor-on-open.md.
    private var emptyStateView: NSView?

    /// Crash net for the no-autosave model: dirty buffers snapshot here and are offered back on
    /// the next launch. A graceful close or save clears its snapshot.
    private var recovery = RecoveryStore(directory: RecoveryStore.appDirectory)
    private var recoverySnapshotTimer: Timer?

    deinit {
        // The run loop retains the timer, so without this each closed dirty window leaks one.
        recoverySnapshotTimer?.invalidate()
    }

    /// Edge pin swapped out while the content width is frozen for a sidebar
    /// slide; see `freezeContentWidth()`.
    private var contentLeading: NSLayoutConstraint?
    private var frozenContentWidth: NSLayoutConstraint?
    /// Top clearance under the host's tab band; see `setTopClearance`.
    private var contentTop: NSLayoutConstraint?

    // MARK: Outline panel

    /// The persistent outline (⌘K) on the column's trailing edge. Push mode pins the content to
    /// the panel; overlay mode floats it above. See docs/specs/2026-09-04-outline-panel-design.md.
    let outlinePanel = OutlinePanelViewController()
    private(set) var isOutlinePanelVisible = false
    /// Fired after the panel opens, closes, resizes or changes mode, so the host can cut it out
    /// of the tab band's paint.
    var onOutlinePanelLayoutChanged: (() -> Void)?
    /// Straddles the panel's leading edge, in THIS view so it can extend over the editor's side.
    private let outlineResizeGrip = ColumnResizeGrip()
    /// Last frame announced through `onOutlinePanelLayoutChanged`, so only a layout pass that
    /// actually moved the panel re-cuts the band.
    private var lastAnnouncedOutlinePanelFrame: CGRect?
    /// The panel's frame in this container's view, nil while hidden.
    var outlinePanelFrame: CGRect? { isOutlinePanelVisible ? outlinePanel.view.frame : nil }
    private(set) var outlinePanelIsOverlay = false
    private var outlinePanelWidth: NSLayoutConstraint?
    /// The panel's trailing pin: 0 when shown, +width when parked off-screen.
    private var outlinePanelTrailing: NSLayoutConstraint?
    private var contentTrailingToEdge: NSLayoutConstraint?
    private var contentTrailingToPanel: NSLayoutConstraint?

    /// The host names the exact band height to clear.
    func setTopClearance(_ clearance: CGFloat) {
        guard let contentTop, abs(contentTop.constant - clearance) > 0.5 else { return }
        contentTop.constant = clearance
    }

    /// The content's real top edge. Overlay covers must use it.
    var topClearance: CGFloat { contentTop?.constant ?? 0 }

    /// Fired when the open tabs change so the host can redraw the strip.
    var onTabsChanged: (([TabItem]) -> Void)?

    /// The ACTIVE tab's editor scroll offset (auto-hiding chrome).
    var onActiveEditorScroll: ((Double) -> Void)?

    /// Band height sent to every web surface as the text's resting top offset. Kept so
    /// late-created tabs and crash reloads get the current value.
    private var chromeTopInset: Double?
    /// docs/motion.md "Zen / normal": the NEXT chrome-top change glides over this duration instead
    /// of snapping. The host arms it around zen's metrics pass and clears it after, so a pass that
    /// changed nothing leaves nothing stale. Only the active surface glides; background tabs are
    /// re-dressed on activate.
    var nextChromeTopGlideDuration: TimeInterval?
    #if DEBUG
    /// Every applied chrome-top change with its glide duration (nil = instant), recorded before
    /// the per-tab sends so a tabless root still records it (ZenTransitionContractTests).
    var chromeTopChangeTrailForTesting: [(inset: Double, duration: TimeInterval?)] = []
    #endif
    func setChromeTopInset(_ inset: Double) {
        guard chromeTopInset != inset else { return }
        let glide = nextChromeTopGlideDuration
        nextChromeTopGlideDuration = nil
        chromeTopInset = inset
        #if DEBUG
        chromeTopChangeTrailForTesting.append((inset: inset, duration: glide))
        #endif
        for tab in tabs {
            if let glide, tab === activeTab {
                tab.surface.setChromeTopInset(inset, animatedOverSeconds: glide)
            } else {
                tab.surface.setChromeTopInset(inset)
            }
        }
        // The fade ends just above the resting first line (inset − 4): it uses the pad below the
        // band for a gradual feather but never washes out resting text. Taller hides the first
        // line; band-only reads as a hard cut.
        chromeFadeHeight?.constant = max(0, CGFloat(inset) - 4)
    }

    private let chromeFade = ChromeFadeView()
    private var chromeFadeHeight: NSLayoutConstraint?

    /// A draft was saved to `url` (first save picked a location), so the host
    /// can refresh the sidebar to show the new file.
    var onDraftSaved: ((URL) -> Void)?
    /// This window's Library roots, handed to every tab's controller (figure search bound).
    var libraryRootsProvider: () -> [URL] = { [] }

    /// In-flight draft save. Non-nil only while the save panel is up, which also guards against a
    /// second Cmd+S opening a second panel.
    private var pendingDraftSave: (tab: Tab, text: String, proposedURL: URL, completion: (Bool) -> Void)?
    private var activeSavePanel: NSSavePanel?

    /// Tab strip callbacks.
    func selectTab(id: UUID) { activate(id: id) }
    func requestCloseTab(id: UUID) { closeTab(id: id) }

    /// Drag-reorder commit: move tab `id` to strip position `index` (clamped). Only the order
    /// changes; session restore serializes `tabs` in order, so it persists.
    func moveTab(id: UUID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let target = max(0, min(index, tabs.count - 1))
        guard from != target else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: target)
        refreshTabBar()
    }

    override func loadView() {
        let root = EditorContainerView()
        root.wantsLayer = true
        // A frozen-width content view can overhang the leading edge mid-slide; it must never
        // paint over the sidebar.
        root.clipsToBounds = true
        root.onAppearanceChange = { [weak self] in
            guard let self else { return }
            self.refreshBackground()
            // Standalone containers (tests) follow their own appearance; under a root that
            // orchestrates the covered transition, this hook stands down.
            guard !self.hostOwnsAppearanceTransitions else { return }
            self.pushAppearance(dark: self.view.effectiveAppearance.isChalkDark,
                                theme: ChalkAppearance.theme)
        }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refreshBackground()

        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)
        addEmptyState() // below the surfaces; shown only while no tab is active

        let leading = contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        contentLeading = leading
        // Top pins to the raw top plus the host's clearance (`setTopClearance`): the editor runs
        // full-bleed under the transparent titlebar with the resting offset done web-side.
        let top = contentView.topAnchor.constraint(equalTo: view.topAnchor)
        contentTop = top
        let trailingToEdge = contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        contentTrailingToEdge = trailingToEdge
        NSLayoutConstraint.activate([
            top,
            leading,
            trailingToEdge,
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Feathers scrolled text out before it reaches the tab chips; sized by `setChromeTopInset`.
        chromeFade.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chromeFade)
        let fadeHeight = chromeFade.heightAnchor.constraint(equalToConstant: 0)
        chromeFadeHeight = fadeHeight
        NSLayoutConstraint.activate([
            chromeFade.topAnchor.constraint(equalTo: view.topAnchor),
            chromeFade.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chromeFade.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fadeHeight,
        ])
        installOutlinePanel()

        // Cross-window save sync. One observer per container, not per tab, so tab close needs no
        // teardown; selector-based observers detach on dealloc.
        NotificationCenter.default.addObserver(
            self, selector: #selector(documentDidSaveElsewhere(_:)),
            name: .chalkDocumentDidSave, object: nil)
    }

    private func refreshBackground() {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.chalkEditorBackground.cgColor
        }
    }

    private func installOutlinePanel() {
        addChild(outlinePanel)
        let panelView: NSView = outlinePanel.view
        panelView.translatesAutoresizingMaskIntoConstraints = false
        // Layer-backed, so the slide moves the panel as one unit: without a
        // layer the panel's own frame snapped to its final place while its
        // layer-backed subviews slid in, a dark block one frame ahead of them.
        panelView.wantsLayer = true
        // Honour a visibility the host set before the view loaded (session restore calls
        // `setOutlinePanelVisible` from the host's `init`). Hiding unconditionally left the flag
        // true over an invisible panel.
        panelView.isHidden = !isOutlinePanelVisible
        // Above the chrome fade: the fade is for text, and over the panel it hid its top.
        view.addSubview(panelView)

        let width = panelView.widthAnchor.constraint(equalToConstant: Preferences.outlinePanelWidth)
        outlinePanelWidth = width
        let trailing = panelView.trailingAnchor.constraint(
            equalTo: view.trailingAnchor,
            constant: isOutlinePanelVisible ? 0 : Preferences.outlinePanelWidth)
        outlinePanelTrailing = trailing
        contentTrailingToPanel = contentView.trailingAnchor.constraint(equalTo: panelView.leadingAnchor)
        NSLayoutConstraint.activate([
            width, trailing,
            panelView.topAnchor.constraint(equalTo: contentView.topAnchor),
            panelView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        outlinePanel.onJump = { [weak self] line in self?.revealLine(line) }

        // The grip straddles the border so a drag on the visible edge catches it from either
        // side. It hides with the panel so the parked panel leaves no phantom strip.
        let grip = outlineResizeGrip
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.isHidden = !isOutlinePanelVisible
        view.addSubview(grip)
        NSLayoutConstraint.activate([
            grip.centerXAnchor.constraint(equalTo: panelView.leadingAnchor),
            grip.widthAnchor.constraint(equalToConstant: 12),
            grip.topAnchor.constraint(equalTo: panelView.topAnchor),
            grip.bottomAnchor.constraint(equalTo: panelView.bottomAnchor),
        ])
        grip.onDragBegan = { [weak self] in
            self?.outlineResizeStartWidth = self?.outlinePanelWidth?.constant ?? 0
        }
        grip.onDragged = { [weak self] dx in
            guard let self else { return }
            self.setOutlinePanelWidth(self.outlineResizeStartWidth - dx, persist: false)
        }
        grip.onDragEnded = { [weak self] in
            guard let self else { return }
            self.setOutlinePanelWidth(self.outlinePanelWidth?.constant ?? 0, persist: true)
        }

        // A pre-load `setOutlinePanelVisible` ran this with nil constraints. The column may still
        // be unsized, so `viewDidLayout` re-evaluates it.
        updateOutlinePanelMode()
    }

    private var outlineResizeStartWidth: CGFloat = 0

    /// Show or hide the panel. The webview reflows inside the container rather than sliding under
    /// chrome, so a plain constraint animation is enough (no WebPaintGate).
    func setOutlinePanelVisible(_ visible: Bool, animated: Bool) {
        guard visible != isOutlinePanelVisible else { return }
        isOutlinePanelVisible = visible
        let panelView: NSView = outlinePanel.view
        if visible {
            panelView.isHidden = false
            outlineResizeGrip.isHidden = false
            updateOutlinePanelMode()
            // Place the panel at its off-screen start before the slide: a
            // hidden view keeps a stale frame, and un-hiding it inside the
            // animated pass showed that frame for one frame at the top
            // trailing corner before the slide began.
            view.layoutSubtreeIfNeeded()
            seedOutlinePanel()
            activeTab?.surface.setOutlineSubscription(true)
        } else {
            activeTab?.surface.setOutlineSubscription(false)
            outlinePanelIsOverlay = false
            contentTrailingToPanel?.isActive = false
            contentTrailingToEdge?.isActive = true
        }
        outlinePanelTrailing?.constant = visible ? 0 : (outlinePanelWidth?.constant ?? 0)
        // Read the live flag, not `visible`: with a fast close-then-open, this hide's completion
        // fires after the reopen.
        let finish = { [weak self] in
            guard let self else { return }
            if !self.isOutlinePanelVisible {
                panelView.isHidden = true
                self.outlineResizeGrip.isHidden = true
            }
            self.onOutlinePanelLayoutChanged?()
        }
        if animated, view.window != nil {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = ChalkMetrics.motionSidebar
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                self.view.layoutSubtreeIfNeeded()
            }, completionHandler: finish)
        } else {
            view.layoutSubtreeIfNeeded()
            finish()
        }
    }

    /// Push while the column can spare the width; overlay once the text
    /// would drop below `ChalkMetrics.outlinePanelPushMinimumEditorWidth`.
    /// Re-evaluated on every layout pass so a window resize flips it.
    private func updateOutlinePanelMode() {
        // Mid-slide the content is trailing-anchored at a frozen width: swapping the trailing pin
        // would jump it sideways. `unfreezeContentWidth` re-evaluates after the reflow.
        guard frozenContentWidth == nil else { return }
        guard isOutlinePanelVisible, let width = outlinePanelWidth?.constant else { return }
        let column = view.bounds.width
        let overlay = column - width < ChalkMetrics.outlinePanelPushMinimumEditorWidth
        let pushActive = contentTrailingToPanel?.isActive ?? false
        guard overlay != outlinePanelIsOverlay || pushActive == overlay else { return }
        outlinePanelIsOverlay = overlay
        contentTrailingToPanel?.isActive = false
        contentTrailingToEdge?.isActive = false
        (overlay ? contentTrailingToEdge : contentTrailingToPanel)?.isActive = true
        onOutlinePanelLayoutChanged?()
    }

    /// Fill the panel from the active tab before the first push lands.
    private func seedOutlinePanel() {
        outlinePanel.setDocumentName(activeTab?.displayName ?? "")
        guard let tab = activeTab else {
            outlinePanel.setSnapshot(.empty)
            return
        }
        tab.surface.fetchOutline { [weak self, weak tab] snapshot in
            guard let self, let tab, self.activeTab === tab, self.isOutlinePanelVisible else { return }
            self.outlinePanel.setSnapshot(snapshot ?? .empty)
        }
    }

    func setOutlinePanelWidth(_ proposed: CGFloat, persist: Bool) {
        let range = Preferences.sidebarWidthRange
        let clamped = min(range.upperBound, max(range.lowerBound, proposed))
        outlinePanelWidth?.constant = clamped
        if !isOutlinePanelVisible { outlinePanelTrailing?.constant = clamped }
        updateOutlinePanelMode()
        if persist { Preferences.outlinePanelWidth = clamped }
        if isOutlinePanelVisible {
            view.layoutSubtreeIfNeeded()
            onOutlinePanelLayoutChanged?()
        }
    }

    /// A DocumentController (possibly in another window) saved `url`. Reuses the external-change
    /// path, which reloads only a clean buffer. The posting controller is already current.
    @objc private func documentDidSaveElsewhere(_ note: Notification) {
        guard let url = note.userInfo?[ChalkNotificationKey.url] as? URL else { return }
        let sender = note.object as? DocumentController
        for tab in tabs {
            guard let tabURL = tab.url, Self.sameFile(tabURL, url),
                  tab.controller !== sender else { continue }
            tab.controller.reloadIfChangedExternally()
        }
    }

    /// Pin the content at its current width (trailing-anchored) for a sidebar slide. The webview
    /// paints asynchronously, so any bounds change mid-animation flashes stale tiles; the caller
    /// animates a pure translation instead and masks the one reflow in `unfreezeContentWidth`.
    func freezeContentWidth() {
        unfreezeContentWidth()
        let frozen = contentView.widthAnchor.constraint(
            equalToConstant: contentView.bounds.width)
        contentLeading?.isActive = false
        frozen.isActive = true
        frozenContentWidth = frozen
    }

    /// The animatable half of the slide, on the caller's clock. The text column is centered, so
    /// half the width change lands it where the post-reflow layout will.
    func slideContent(by offset: CGFloat, over duration: TimeInterval) {
        contentView.layer?.chalkSlide(toTranslationX: offset, over: duration)
    }

    /// Restore edge-pinning: the transition's single width reflow, while nothing is moving.
    func unfreezeContentWidth() {
        guard let frozen = frozenContentWidth else { return }
        #if DEBUG
        reflowCountForTesting += 1
        #endif
        frozen.isActive = false
        frozenContentWidth = nil
        contentView.layer?.chalkEndSlide()
        contentLeading?.isActive = true
        view.layoutSubtreeIfNeeded()
        // The slide may have crossed the push/overlay threshold while frozen.
        updateOutlinePanelMode()
    }

    #if DEBUG
    /// Contract probes (SidebarSlideContractTests). Counts only unfreezes that released a frozen
    /// width, so "one transition, one reflow" is assertable.
    private(set) var reflowCountForTesting = 0
    var isContentWidthFrozenForTesting: Bool { frozenContentWidth != nil }
    var contentTransformForTesting: CGAffineTransform {
        contentView.layer.map { CATransform3DGetAffineTransform($0.transform) } ?? .identity
    }
    /// Bounds, not frame: the slide moves the frame; the contract is that the size never changes.
    var contentViewBoundsForTesting: CGRect { contentView.bounds }
    var contentViewForTesting: NSView { contentView }
    #endif

    /// The active tab's webview, for the snapshot that masks the unfreeze reflow.
    var activeSurfaceWebView: WKWebView? {
        (activeTab?.surface as? WebEditorSurface)?.webView
    }

    #if DEBUG
    /// Downcasts to the web surface: these readers are implementation evidence, not part of the
    /// `EditorSurface` seam.
    /// The active web surface, for the debug script's page-side actions.
    var activeWebSurfaceForDebug: WebEditorSurface? { activeWebSurfaceForTesting }
    private var activeWebSurfaceForTesting: WebEditorSurface? {
        activeTab?.surface as? WebEditorSurface
    }
    /// The theme the active surface will show. Nil when no tab is open.
    var activeSurfaceDesiredDarkForTesting: Bool? {
        activeWebSurfaceForTesting?.desiredDarkForTesting
    }
    /// How many appearance pushes the active surface has taken.
    var activeSurfaceAppearancePushCountForTesting: Int {
        activeWebSurfaceForTesting?.appearancePushCountForTesting ?? 0
    }
    /// The heading palette the active surface was last handed.
    var activeSurfaceHeadingColorsForTesting: HeadingColors? {
        activeWebSurfaceForTesting?.headingColorsForTesting
    }
    private var lastTracedLayout = ""
    #endif

    override func viewDidLayout() {
        super.viewDidLayout()
        #if DEBUG
        let line = "layout content=\(contentView.frame) active=\(activeTab?.surface.view.frame ?? .zero) panelHidden=\(outlinePanel.isViewLoaded ? outlinePanel.view.isHidden : true) panel=\(outlinePanel.isViewLoaded ? outlinePanel.view.frame : .zero) frozen=\(frozenContentWidth != nil)"
        if line != lastTracedLayout { lastTracedLayout = line; DebugTrace.log(line) }
        #endif
        syncActiveSurfaceAppearance()
        updateOutlinePanelMode()
        let panelFrame = outlinePanelFrame
        if panelFrame != lastAnnouncedOutlinePanelFrame {
            lastAnnouncedOutlinePanelFrame = panelFrame
            onOutlinePanelLayoutChanged?()
        }
    }

    /// Make the active surface agree with the resolved appearance; a no-op when it already does.
    /// The launch tab is activated before this container has a window, so its appearance reads
    /// the system's and the page comes up light under dark chrome; layout catches that. It cannot
    /// fight a covered transition, which flips the appearance and pushes the theme in one turn.
    func syncActiveSurfaceAppearance() {
        guard view.window != nil, activeTab != nil else { return }
        let dark = view.effectiveAppearance.isChalkDark
        let theme = ChalkAppearance.theme
        guard pushedDark != dark || pushedTheme != theme else { return }
        pushAppearance(dark: dark, theme: theme)
    }

    /// What the ACTIVE surface was last told, so a resync can tell "already agrees" from "never
    /// heard". Reset on activate.
    private var pushedDark: Bool?
    private var pushedTheme: ChalkTheme?

    /// Set when the host runs the covered appearance transition and pushes the theme itself
    /// (docs/motion.md "Appearance"); the appearance hook then stands down, since it would flip
    /// the page outside the cover. Standalone containers (tests) keep the hook.
    var hostOwnsAppearanceTransitions = false

    /// The orchestrator's push (active surface only).
    func pushAppearance(dark: Bool, theme: ChalkTheme) {
        pushedDark = dark
        pushedTheme = theme
        if let surface = activeTab?.surface {
            pushAppearance(to: surface, dark: dark, theme: theme)
        }
    }

    /// Theme and heading palette always travel together: the palette depends on the appearance,
    /// so pushing one alone can leave dark-theme headings on light paper.
    private func pushAppearance(to surface: EditorSurface, dark: Bool, theme: ChalkTheme) {
        surface.setAppearance(dark: dark, theme: theme)
        surface.setHeadingColors(headingColors(dark: dark))
    }

    /// An EMPTY payload when the preference is off, never "send nothing": the editor clears
    /// missing levels, which is what hands headings back to the stylesheet.
    private func headingColors(dark: Bool) -> HeadingColors {
        Preferences.colorHeadings
            ? MarkdownHeadingPalette.colors(dark: dark)
            : MarkdownHeadingPalette.none
    }

    /// Settings toggled "Color Markdown Headings": re-push to every open tab.
    func applyHeadingColors() {
        let dark = pushedDark ?? view.effectiveAppearance.isChalkDark
        let colors = headingColors(dark: dark)
        for tab in tabs { tab.surface.setHeadingColors(colors) }
    }

    // MARK: - Commands (driven by the coordinator)

    /// Open `url` in its existing tab or a new one. `reuseCurrentIfClean` (sidebar click) browses
    /// an uncommitted active tab to `url` in place. `activating: false` (session restore) leaves
    /// the new tab's surface dormant, with no webview boot.
    func open(url: URL, reuseCurrentIfClean: Bool = false, activating: Bool = true) {
        loadViewIfNeeded() // open() can be called before this VC is on screen
        if let existing = tabs.first(where: { $0.url.map { Self.sameFile($0, url) } ?? false }) {
            if activating { activate(existing) }
            return
        }
        // Reuse only an uncommitted file-backed tab: never a draft or a tab that was edited or
        // saved. A tab whose restore-open failed reads clean but still holds crash edits.
        if reuseCurrentIfClean, let active = activeTab,
           active.url != nil, !active.isCommitted,
           !active.controller.hasUnappliedRecovery {
            active.url = url                 // update the dedupe key + chip title
            active.controller.reopen(url: url)
            // Through activate, not a bare refreshTabBar, so a detached surface is re-installed.
            activate(active)
            return
        }
        let tab = Tab(url: url)
        adopt(tab)
        tab.controller.open(url: url)
        if activating {
            activate(tab)
        } else {
            refreshTabBar() // the chip must appear even for a dormant tab
        }
    }

    /// Shared new-tab setup: wire the controller and seed the surface with current settings.
    private func adopt(_ tab: Tab) {
        tab.controller.delegate = self
        tab.controller.libraryRootsProvider = { [weak self] in self?.libraryRootsProvider() ?? [] }
        // The surface exhausted its boot recovery: tell the user rather than show a blank tab.
        tab.surface.onFailedToBecomeReady = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.presentSurfaceLoadFailure(for: tab)
        }
        tab.surface.setFontScale(Preferences.editorFontScale)
        tab.surface.setEditorConfig(Preferences.editorConfigPayload(editingMode: currentEditingMode()))
        let surface = tab.surface
        if let inset = chromeTopInset { surface.setChromeTopInset(inset) }
        surface.setMeasure(Preferences.editorMeasure)
        surface.setLineHeight(Preferences.editorLineHeight)
        surface.setTextAlign(Preferences.textAlignment)
        surface.onScroll = { [weak self, weak tab] y in
            guard let self, let tab, self.activeTab === tab else { return }
            self.onActiveEditorScroll?(y)
        }
        surface.onOutline = { [weak self, weak tab] snapshot in
            guard let self, let tab, self.activeTab === tab, self.isOutlinePanelVisible else { return }
            self.outlinePanel.setSnapshot(snapshot)
        }
        tabs.append(tab)
    }

    /// The webview never became ready, even after a reload. Buffer and file are untouched.
    private func presentSurfaceLoadFailure(for tab: Tab) {
        presentChalkNotice(
            title: "Editor Failed to Load",
            message: "The editor for \u{201C}\(tab.displayName)\u{201D} didn\u{2019}t start. Your file is untouched. Try closing the tab and reopening it; if this keeps happening, reinstall the app.")
    }

    /// The document read failed (revoked scope, unreadable file, fd exhaustion). Retry reopens in
    /// the same tab; Close removes it so chip and body agree. Without a window to sheet on
    /// (tests), the tab simply stays, which is also the sheet's Cancel.
    private func presentDocumentOpenFailure(for tab: Tab, url: URL) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn\u{2019}t Open \u{201C}\(tab.displayName)\u{201D}"
        alert.informativeText = "The file couldn\u{2019}t be read. It may have moved, or access was denied. The file on disk is untouched."
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Close Tab")
        alert.beginSheetModal(for: window) { [weak self, weak tab] response in
            guard let self, let tab else { return }
            switch response {
            case .alertFirstButtonReturn:
                tab.controller.reopen(url: url)
                self.activate(tab)
            default:
                self.performClose(tab)
            }
        }
    }

    /// A one-button notice in the window's sheet. Logged instead when there is no window.
    func presentChalkNotice(title: String, message: String) {
        guard let window = view.window else {
            containerLog.notice("notice without a window: \(title, privacy: .public)")
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// Apply an editor zoom to every open tab.
    func setFontScale(_ scale: Double) {
        tabs.forEach { $0.surface.setFontScale(scale) }
    }

    /// Last values pushed, recorded only for tests. `adopt` seeds new tabs from `Preferences`.
    private(set) var lastPushedMeasure: Double?
    private(set) var lastPushedTextAlign: EditorTextAlignment?
    private(set) var lastPushedLineHeight: Double?

    /// Apply the text column width (Settings slider) to every open tab.
    func setMeasure(_ px: Double) {
        lastPushedMeasure = px
        for tab in tabs { tab.surface.setMeasure(px) }
    }

    /// Apply the interline spacing (Settings slider) to every open tab.
    func setLineHeight(_ multiplier: Double) {
        lastPushedLineHeight = multiplier
        for tab in tabs { tab.surface.setLineHeight(multiplier) }
    }

    /// Apply the wrapped-prose alignment (Settings) to every open tab.
    func setTextAlign(_ alignment: EditorTextAlignment) {
        lastPushedTextAlign = alignment
        for tab in tabs { tab.surface.setTextAlign(alignment) }
    }

    /// Send the editor config to every open tab, with this window's editing mode, never the
    /// global preference (another window may have set it last).
    func applyEditorConfig() {
        let payload = Preferences.editorConfigPayload(editingMode: currentEditingMode())
        tabs.forEach { $0.surface.setEditorConfig(payload) }
    }

    /// Push freshly composed hsnips to every open tab.
    func setHsnips(_ content: String) {
        tabs.forEach { $0.surface.setHsnips(content: content) }
    }

    /// Re-read any open file that changed on disk (called on foreground).
    func reloadExternalChanges() {
        tabs.forEach { $0.controller.reloadIfChangedExternally() }
    }

    /// Cmd+S on the active tab. Explicit, so it commits the tab, unlike `saveAll`.
    func save() { activeTab?.controller.save(explicit: true) }

    /// Return keyboard focus to the active editor, e.g. after dismissing Quick Open or Settings.
    func focusActiveSurface() { activeTab?.surface.focusEditor() }

    /// Outline and cursor line of the active tab; nil when no tab is open.
    func fetchActiveOutline(completion: @escaping (OutlineSnapshot?) -> Void) {
        guard let tab = activeTab else {
            completion(nil)
            return
        }
        tab.surface.fetchOutline(completion: completion)
    }

    /// Jump the active tab's editor to a 1-based line (outline palette row).
    func revealLine(_ line: Int) { activeTab?.surface.revealLine(line) }

    /// Release the active editor's keyboard claim (DOM + native) so an
    /// overlay's text field can take focus without WebKit re-asserting.
    func blurActiveSurface() { activeTab?.surface.blurEditor() }

    /// A shell command forwarded from a page (the keys the page consumes, see
    /// `SHELL_COMMANDS` in native-host.ts).
    var onShellCommand: ((String) -> Void)?

    /// Flush every file-backed tab (clean ones no-op) on resign-active. Drafts are skipped: saving
    /// one would present the save panel. `completion` fires once every async write has landed.
    func saveAll(completion: (() -> Void)? = nil) {
        let group = DispatchGroup()
        for tab in tabs where tab.url != nil {
            group.enter()
            tab.controller.save { _ in group.leave() }
        }
        group.notify(queue: .main) { completion?() }
    }

    func closeActiveTab() { if let tab = activeTab { close(tab) } }

    /// Cmd+W falls through to closing the window when nothing is open.
    var hasOpenTabs: Bool { !tabs.isEmpty }
    /// Drafts included.
    var openTabCount: Int { tabs.count }
    /// Editor half of the window's state line: tells an empty window from one whose live tab
    /// shows no surface. Never names the file: the line is logged `.public`.
    var diagnosticSummary: String {
        let kind = activeTab == nil ? "none" : (activeTab?.url == nil ? "draft" : "file")
        let installed = activeTab.map { $0.surface.view.superview != nil }
        let placeholder = emptyStateView.map { !$0.isHidden }
        return "active=\(kind) surfaceInstalled=\(installed.map(String.init) ?? "n/a")"
            + " placeholder=\(placeholder.map(String.init) ?? "n/a")"
    }

    func nextTab() { cycle(+1) }
    func previousTab() { cycle(-1) }

    // MARK: - Window restoration

    /// File-backed tab URLs in strip order and the active tab's index. Drafts are skipped, so the
    /// index counts the returned URLs, not `tabs`.
    func sessionSnapshot() -> (urls: [URL], activeIndex: Int?) {
        let fileTabs = tabs.filter { $0.url != nil }
        let urls = fileTabs.compactMap(\.url)
        let activeIndex = fileTabs.firstIndex { $0 === activeTab }
        return (urls, activeIndex)
    }

    /// Activate by strip position (restoration; ignores out-of-range).
    func activateTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activate(tabs[index])
    }

    // MARK: - Crash recovery

    /// Snapshot ids re-keyed onto a live tab this process. The leftover drain must skip them:
    /// they are live dirty state, and recovering them would open duplicate tabs.
    private static var claimedRecoveryIDs = Set<String>()

    /// Reopen buffers a crash or force-quit left behind. A snapshot whose file is already open
    /// layers onto that tab as unsaved edits (it is newer than disk); otherwise it opens in a new
    /// tab, or as a draft if the file is gone. Each snapshot is re-keyed under its new tab id
    /// BEFORE the old record is cleared, so a failed open never loses the text.
    /// With `matchingOwnTabsOnly`, a restoring window claims only records matching its own
    /// restored tabs; the process-wide leftover drain (`false`) runs once, a turn later.
    func restoreRecoveredBuffers(matchingOwnTabsOnly: Bool = false) {
        loadViewIfNeeded()
        for record in recovery.pending() {
            // A record stamped by THIS launch is live dirty state some window owns, not crash
            // residue; layering it would resurrect seconds-old text. nil counts as residue.
            guard record.launchID != RecoveryStore.currentLaunchID else { continue }
            // Already re-keyed onto a live tab (possibly in another window): don't steal it.
            guard !Self.claimedRecoveryIDs.contains(record.id) else { continue }
            if let url = record.fileURL, FileManager.default.fileExists(atPath: url.path) {
                if let existing = tabs.first(where: { $0.url.map { Self.sameFile($0, url) } ?? false }) {
                    existing.controller.layerRecoveredText(record.text)
                    writeSnapshot(id: existing.id.uuidString, text: record.text, fileURL: url)
                    Self.claimedRecoveryIDs.insert(existing.id.uuidString)
                    if record.id != existing.id.uuidString { recovery.clear(id: record.id) }
                    continue
                }
                guard !matchingOwnTabsOnly else { continue } // leftover drain's job
                let tab = Tab(url: url)
                adopt(tab)
                tab.controller.open(url: url, recoveredText: record.text)
                activate(tab)
                writeSnapshot(id: tab.id.uuidString, text: record.text, fileURL: url)
                Self.claimedRecoveryIDs.insert(tab.id.uuidString)
                recovery.clear(id: record.id)
            } else {
                guard !matchingOwnTabsOnly else { continue } // leftover drain's job
                let openDraftTitles = tabs.compactMap { $0.url == nil ? $0.displayName : nil }
                let tab = Tab(draftTitle: DraftNaming.nextUntitledTitle(existing: openDraftTitles))
                adopt(tab)
                tab.controller.openDraft(
                    language: Preferences.defaultFileType.language, recoveredText: record.text)
                activate(tab)
                writeSnapshot(id: tab.id.uuidString, text: record.text, fileURL: nil)
                Self.claimedRecoveryIDs.insert(tab.id.uuidString)
                recovery.clear(id: record.id)
            }
        }
    }

    /// Snapshot every dirty tab now and drop snapshots of clean ones. Called by the timer and on
    /// resign-active. Text is captured on main (COW, O(1)) and encoded and written on
    /// `recoveryQueue`.
    func snapshotDirtyBuffers() {
        var writes: [(id: String, text: String, fileURL: URL?)] = []
        var clears: [String] = []
        for tab in tabs {
            if tab.isDirty {
                writes.append((tab.id.uuidString, tab.controller.currentText, tab.url))
            } else if !tab.controller.hasUnappliedRecovery {
                // A failed restore-open reads clean, but its snapshot is the only copy of the
                // crash edits.
                clears.append(tab.id.uuidString)
            }
        }
        guard !writes.isEmpty || !clears.isEmpty else { return }
        let store = recovery
        recoveryQueue.async {
            for w in writes { Self.writeSnapshot(to: store, id: w.id, text: w.text, fileURL: w.fileURL) }
            for id in clears { store.clear(id: id) }
        }
    }

    /// Serializes every recovery-store mutation outside the startup drain. A save's clear must
    /// land after any queued write for the same id, or stale pre-save text resurrects at the next
    /// launch. The drain stays synchronous on main: it runs before any batch can queue.
    private let recoveryQueue = DispatchQueue(label: "com.huleux.chalk.recovery", qos: .utility)

    /// Route a clean-tab clear through the queue (see recoveryQueue ordering).
    private func clearSnapshotQueued(id: String) {
        let store = recovery
        recoveryQueue.async { store.clear(id: id) }
    }

    /// Logs failures, so an empty recovery can be traced (full disk, missing dir).
    private static func writeSnapshot(to store: RecoveryStore, id: String, text: String, fileURL: URL?) {
        do {
            try store.snapshot(id: id, text: text, fileURL: fileURL)
        } catch {
            containerLog.error("recovery snapshot failed for \(fileURL?.lastPathComponent ?? "draft", privacy: .private): \(DiagError(error), privacy: .public)")
        }
    }

    /// Synchronous write for the startup drain (see recoveryQueue note).
    private func writeSnapshot(id: String, text: String, fileURL: URL?) {
        Self.writeSnapshot(to: recovery, id: id, text: text, fileURL: fileURL)
    }

    /// Run the snapshot timer exactly while at least one tab is dirty.
    private func updateRecoveryTimer() {
        let anyDirty = tabs.contains { $0.isDirty }
        if anyDirty, recoverySnapshotTimer == nil {
            let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
                self?.snapshotDirtyBuffers()
            }
            timer.tolerance = 2
            // .common, not .default: the default mode pauses during scroll and menu tracking.
            RunLoop.main.add(timer, forMode: .common)
            recoverySnapshotTimer = timer
        } else if !anyDirty {
            recoverySnapshotTimer?.invalidate()
            recoverySnapshotTimer = nil
        }
    }

    #if DEBUG
    /// The strip snapshot the next refreshTabBar() would publish (unit tests).
    var tabItemsForTesting: [TabItem] { makeTabItems() }

    /// Every URL whose open failure reached the user, so a test can wait for the failure itself.
    private(set) var openFailuresForTesting: [URL] = []

    /// The file a draft save proposes to the save panel, while the save is pending.
    var pendingDraftSaveFileForTesting: URL? { pendingDraftSave?.proposedURL }

    var isEmptyStateVisibleForTesting: Bool {
        guard let emptyStateView else { return false }
        return !emptyStateView.isHidden
    }

    var contentViewFrameForTesting: CGRect { contentView.frame }

    var outlinePanelWidthForTesting: CGFloat { outlinePanelWidth?.constant ?? 0 }
    var outlineResizeGripFrameForTesting: CGRect { outlineResizeGrip.frame }
    var outlineResizeGripIsHiddenForTesting: Bool { outlineResizeGrip.isHidden }
    var isOutlinePanelAboveChromeFadeForTesting: Bool {
        guard let panel = view.subviews.firstIndex(of: outlinePanel.view),
              let fade = view.subviews.firstIndex(of: chromeFade) else { return false }
        return panel > fade
    }
    /// nil when there is no such tab.
    func outlineSubscriptionForTesting(tabAt index: Int) -> Bool? {
        guard tabs.indices.contains(index) else { return nil }
        return (tabs[index].surface as? WebEditorSurface)?.isOutlineSubscribedForTesting
    }
    /// "edge" (full-width or overlay) or "panel" (push). Exactly one pin must ever be active.
    var activeContentTrailingPinForTesting: String {
        let edge = contentTrailingToEdge?.isActive ?? false
        let panel = contentTrailingToPanel?.isActive ?? false
        precondition(edge != panel, "exactly one content trailing pin must be active")
        return edge ? "edge" : "panel"
    }

    var chromeTopInsetForTesting: Double { chromeTopInset ?? -1 }

    /// Point the crash net at a test-owned store (tests must never touch the real one), and reset
    /// the process-wide claimed ids so drain tests are order-independent.
    func setRecoveryStoreForTesting(_ store: RecoveryStore) {
        recovery = store
        Self.claimedRecoveryIDs.removeAll()
    }

    /// Blocks until every queued recovery mutation has landed.
    func drainRecoveryQueueForTesting() {
        recoveryQueue.sync {}
    }

    func tabControllerForTesting(at index: Int) -> DocumentController? {
        tabs.indices.contains(index) ? tabs[index].controller : nil
    }

    func tabSurfaceForTesting(at index: Int) -> WebEditorSurface? {
        tabs.indices.contains(index) ? tabs[index].surface as? WebEditorSurface : nil
    }

    var tabCountForTesting: Int { tabs.count }

    /// Closes all but the first `keep` tabs via the normal close path (audit harness overflow state).
    func closeAllButFirstForAudit(keeping keep: Int) {
        for tab in Array(tabs.dropFirst(keep)) { close(tab) }
    }

    /// Closes every open tab. Audit states have no dirty buffers, so no confirm-close fires.
    func closeAllTabsForAudit() {
        for tab in Array(tabs) { close(tab) }
    }
    #endif

    /// New in-memory draft in a new tab; nothing touches disk until the first save picks a
    /// location. The chip title is session-only.
    func newFile() {
        loadViewIfNeeded() // newFile() can be called before this VC is on screen
        let openDraftTitles = tabs.compactMap { $0.url == nil ? $0.displayName : nil }
        let tab = Tab(draftTitle: DraftNaming.nextUntitledTitle(existing: openDraftTitles))
        adopt(tab)
        tab.controller.openDraft(language: Preferences.defaultFileType.language)
        activate(tab)
    }

    /// A file or folder was renamed or moved. Re-point every tab at or under `oldURL` instead of
    /// closing it; unsaved edits survive since the buffer lives in the `DocumentController`.
    func handleFileMoved(from oldURL: URL, to newURL: URL) {
        var changed = false
        for tab in tabs {
            guard let url = tab.url,
                  let remapped = FileMove.remap(url: url, from: oldURL, to: newURL) else { continue }
            tab.url = remapped
            tab.controller.rebind(to: remapped)
            changed = true
        }
        if changed { refreshTabBar() }
    }

    // MARK: - Internals

    /// Tab-dedupe comparison. A raw `URL ==` misses aliases such as `/private/var/…` versus
    /// `/var/…`, which would open one file in two tabs.
    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        a.fileIdentity == b.fileIdentity
    }

    private func activate(_ tab: Tab) {
        if activeTab !== tab {
            let outgoingSurface = activeTab?.surface
            if isOutlinePanelVisible { activeTab?.surface.setOutlineSubscription(false) }
            activeTab = tab
            // Dress the incoming surface (appearance, chrome-top) BEFORE install, so it never
            // flashes a stale theme or band height (docs/motion.md "Tab switch").
            pushedDark = view.effectiveAppearance.isChalkDark
            pushedTheme = ChalkAppearance.theme
            pushAppearance(to: tab.surface, dark: pushedDark == true, theme: ChalkAppearance.theme)
            #if DEBUG
            activateEventTrailForTesting.append("appearance")
            #endif
            if let inset = chromeTopInset {
                tab.surface.setChromeTopInset(inset)
                #if DEBUG
                activateEventTrailForTesting.append("chrome-top")
                #endif
            }
            ensureInstalled(tab)
            #if DEBUG
            activateEventTrailForTesting.append("install")
            #endif
            if isOutlinePanelVisible {
                seedOutlinePanel()
                tab.surface.setOutlineSubscription(true)
            }
            if let outgoingSurface, outgoingSurface.view !== tab.surface.view {
                crossFade(from: outgoingSurface, to: tab.surface)
            }
        } else {
            // Re-activating the active tab still installs, so a detached surface is repaired.
            ensureInstalled(tab)
        }
        refreshEmptyState()
        refreshTabBar()
        // Every activation focuses the editor, a turn later so the triggering control (tab chip,
        // Library row) has finished its click and can't pull first responder back.
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self, let tab, self.activeTab === tab else { return }
            tab.surface.focusEditor()
        }
    }

    /// docs/motion.md "Tab switch": a cross-fade with both surfaces hosted and geometry untouched.
    /// On AppKit the fade is on a BITMAP of the outgoing page: a web view's content is a remote
    /// layer that ignores an ancestor's alpha, so an alpha cross-fade cut in one frame. The
    /// incoming goes in under the outgoing, which keeps the screen until its snapshot lands (or
    /// the backstop gives up on it); then the bitmap replaces it on top and fades out.
    /// Reduce Motion, the instant test policy and an unhosted container swap instantly.
    private func crossFade(from outgoingSurface: EditorSurface, to incomingSurface: EditorSurface) {
        let outgoing = outgoingSurface.view
        let incoming = incomingSurface.view
        incoming.alphaValue = 1
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, !motionIsInstant,
              incoming.window != nil else {
            #if DEBUG
            DebugTrace.log("tab cross-fade: instant swap")
            #endif
            outgoing.removeFromSuperview()
            return
        }
        contentView.addSubview(incoming, positioned: .below, relativeTo: outgoing)
        var swapped = false
        let swap: (NSImage?) -> Void = { [weak self] image in
            guard !swapped, let self else { return }
            swapped = true
            // A rapid switch can make `outgoing` active again before its bitmap lands: never
            // remove it then, and never paint a stale bitmap over it.
            guard outgoing !== self.activeTab?.surface.view else { return }
            guard let image else {
                outgoing.removeFromSuperview()
                return
            }
            let bitmap = NSImageView(image: image)
            bitmap.imageScaling = .scaleAxesIndependently
            bitmap.wantsLayer = true
            bitmap.frame = outgoing.frame
            self.contentView.addSubview(bitmap, positioned: .above, relativeTo: nil)
            outgoing.removeFromSuperview()
            #if DEBUG
            self.activateEventTrailForTesting.append("fade-begin")
            DebugTrace.log("tab cross-fade: bitmap fade over \(ChalkMetrics.motionFast)")
            #endif
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = ChalkMetrics.motionFast
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bitmap.animator().alphaValue = 0
            }, completionHandler: {
                bitmap.removeFromSuperview()
            })
        }
        // Always a turn later, even for a surface that answers at once: the contract is both
        // surfaces hosted through the switch's turn (TabSwitchContractTests).
        outgoingSurface.captureSnapshot { image in DispatchQueue.main.async { swap(image) } }
        // A snapshot that never lands (a page that is not up) must not hold the old page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { swap(nil) }
    }

    #if DEBUG
    /// Set by the root's `.instant` motion policy so the tab cross-fade settles in runloop turns.
    var motionIsInstantForTesting = false
    /// Ordered activate-path events (TabSwitchContractTests).
    var activateEventTrailForTesting: [String] = []
    #endif
    private var motionIsInstant: Bool {
        #if DEBUG
        return motionIsInstantForTesting
        #else
        return false
        #endif
    }

    /// The single surface-install site. Removal drops the edge constraints, so each install
    /// activates a fresh set.
    private func ensureInstalled(_ tab: Tab) {
        tab.surface.bootIfNeeded() // dormant until first shown (fd bound)
        let editorView = tab.surface.view
        guard editorView.superview == nil else { return }
        editorView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(editorView)
        NSLayoutConstraint.activate([
            editorView.topAnchor.constraint(equalTo: contentView.topAnchor),
            editorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            editorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func activate(id: UUID) {
        if let tab = tabs.first(where: { $0.id == id }) { activate(tab) }
    }

    private func close(_ tab: Tab) {
        if tab.isDirty {
            confirmClose(tab)
        } else {
            performClose(tab)
        }
    }

    private func closeTab(id: UUID) {
        if let tab = tabs.first(where: { $0.id == id }) { close(tab) }
    }

    private func performClose(_ tab: Tab) {
        // A deliberate close must not resurrect at the next launch, unless the tab still holds
        // unapplied crash-recovered text: that snapshot is the only copy, so the next drain retries.
        if !tab.controller.hasUnappliedRecovery {
            clearSnapshotQueued(id: tab.id.uuidString)
        }
        let wasActive = activeTab === tab
        let index = tabs.firstIndex { $0 === tab }
        tab.surface.view.removeFromSuperview()
        tab.surface.teardown()
        tab.controller.close()
        if let index { tabs.remove(at: index) }

        if wasActive {
            activeTab = nil
            if !tabs.isEmpty {
                let neighbor = tabs[min(index ?? 0, tabs.count - 1)]
                activate(neighbor)
            } else {
                if isOutlinePanelVisible { seedOutlinePanel() }
                refreshEmptyState()
                refreshTabBar()
            }
        } else {
            refreshTabBar()
        }
    }

    private func cycle(_ delta: Int) {
        guard let active = activeTab, tabs.count > 1,
              let i = tabs.firstIndex(where: { $0 === active }) else { return }
        activate(tabs[(i + delta + tabs.count) % tabs.count])
    }

    /// Save, Discard, Cancel as a window sheet. Without a window (tests) the tab stays, which is
    /// Cancel.
    private func confirmClose(_ tab: Tab) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Save changes to \u{201C}\(tab.displayName)\u{201D}?"
        alert.addButton(withTitle: "Save")
        let discard = alert.addButton(withTitle: "Discard")
        discard.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                // Close only on a confirmed write; a failed save keeps the tab and its buffer.
                tab.controller.save { ok in if ok { self?.performClose(tab) } }
            case .alertSecondButtonReturn:
                self?.performClose(tab)
            default:
                break
            }
        }
    }

    private func refreshTabBar() {
        onTabsChanged?(makeTabItems())
    }

    /// The placeholder shows exactly when no tab is active. Every `activeTab` mutation goes
    /// through `activate(_:)` or `performClose(_:)`, which both lead here.
    private func refreshEmptyState() {
        emptyStateView?.isHidden = activeTab != nil
    }

    /// The active file, for the Library's open-document mark. Nil for a draft.
    var activeDocumentURL: URL? { activeTab?.url }

    private func makeTabItems() -> [TabItem] {
        // The "folder/" prefix shows only where another open tab has the same filename.
        let needsPrefix = TabStripPolicy.needsFolderPrefix(names: tabs.map(\.displayName))
        return tabs.enumerated().map { index, tab in
            TabItem(id: tab.id, name: tab.displayName, isDirty: tab.isDirty,
                    isActive: tab === activeTab,
                    // Preview: a file-backed tab not yet committed (what a sidebar click reuses).
                    isPreview: tab.url != nil && !tab.isCommitted,
                    folder: needsPrefix[index]
                        ? tab.url.flatMap(TabStripPolicy.folderPrefix(for:))
                        : nil)
        }
    }

    private func addEmptyState() {
        let title = NSTextField(labelWithString: "No document open")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .chalkTextSecondary

        let hint = NSTextField(labelWithString: "Open a file from the Library, or press \u{2318}N")
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = .chalkTextFaint

        let stack = NSStackView(views: [title, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        emptyStateView = stack
        refreshEmptyState()
    }
}

extension EditorContainerViewController: DocumentControllerDelegate {
    func documentController(_ controller: DocumentController, didChangeDirty isDirty: Bool) {
        guard let tab = tabs.first(where: { $0.controller === controller }) else { return }
        tab.isDirty = isDirty
        // Editing commits the tab (no longer a preview).
        if isDirty { tab.isCommitted = true }
        // Drop the snapshot once clean, queued behind any in-flight write for this id. Not while
        // recovered text is unapplied: a failed restore-open reports clean, and the snapshot is
        // then the only copy.
        if !isDirty, !controller.hasUnappliedRecovery {
            clearSnapshotQueued(id: tab.id.uuidString)
        }
        updateRecoveryTimer()
        refreshTabBar()
    }

    func documentController(_ controller: DocumentController, requestsShellCommand name: String) {
        onShellCommand?(name)
    }

    /// A save wrote real changes (never fired for no-op saves, so a resign-active `saveAll` leaves
    /// untouched previews alone). Commit the tab so a sidebar click no longer replaces it.
    func documentControllerDidSave(_ controller: DocumentController) {
        guard let tab = tabs.first(where: { $0.controller === controller }), !tab.isCommitted else { return }
        tab.isCommitted = true
        refreshTabBar()
    }

    /// A deliberate Cmd+S, even with nothing to write, commits a browsed tab. Drafts are committed
    /// when the save panel binds them.
    func documentControllerDidRequestExplicitSave(_ controller: DocumentController) {
        guard let tab = tabs.first(where: { $0.controller === controller }),
              tab.url != nil, !tab.isCommitted else { return }
        tab.isCommitted = true
        refreshTabBar()
    }

    /// A save failed; the buffer is intact, so tell the user their work is safe.
    func documentController(_ controller: DocumentController, didFailSaveTo url: URL) {
        presentChalkNotice(
            title: "Couldn\u{2019}t Save \u{201C}\(url.lastPathComponent)\u{201D}",
            message: "Your changes are still in the editor. Check that the file\u{2019}s location is available and try again.")
    }

    /// A save overwrote an external change. The write already happened, so this only informs,
    /// stating what actually happened to the other version: sibling copy, recovery-folder copy
    /// (sandbox denied the sibling), or no copy.
    func documentController(_ controller: DocumentController,
                            hasSaveConflictAt url: URL, backupAt backupURL: URL?) {
        let message: String
        if let backupURL, backupURL.deletingLastPathComponent() == url.deletingLastPathComponent() {
            message = "Your version was saved. A copy of the other version was kept as \u{201C}\(backupURL.lastPathComponent)\u{201D} in the same folder."
        } else if let backupURL {
            message = "Your version was saved. A copy of the other version was kept as \u{201C}\(backupURL.lastPathComponent)\u{201D} in Chalk\u{2019}s own folder, which Privacy in Settings can reveal."
        } else {
            message = "Your version was saved. The other version could not be copied aside and was overwritten."
        }
        presentChalkNotice(
            title: "\u{201C}\(url.lastPathComponent)\u{201D} Changed Outside This Window",
            message: message)
    }

    func documentController(_ controller: DocumentController, didFailToOpen url: URL) {
        guard let tab = tabs.first(where: { $0.controller === controller }) else { return }
        #if DEBUG
        openFailuresForTesting.append(url)
        #endif
        presentDocumentOpenFailure(for: tab, url: url)
    }

    /// A draft asked to save: propose a name in the draft's own language and present the save
    /// panel as a sheet. `completion(false)` on any early-out or cancel, so confirm-close keeps
    /// the tab. Without a window (tests) the proposal is recorded and nothing is presented.
    func documentController(_ controller: DocumentController,
                            needsSaveDestination completion: @escaping (Bool) -> Void) {
        guard let tab = tabs.first(where: { $0.controller === controller }), tab.url == nil else {
            completion(false)
            return
        }
        // A pending save with no panel up means the panel vanished without a callback; clear it
        // or draft saving stays wedged for the session.
        if let stale = pendingDraftSave, activeSavePanel == nil {
            pendingDraftSave = nil
            stale.completion(false)
        }
        // A second Cmd+S while the panel is up must not present another.
        guard pendingDraftSave == nil, activeSavePanel == nil else {
            completion(false)
            return
        }

        let text = controller.currentText
        // The draft's own language: the default-file-type preference may have changed since.
        let name = "\(tab.displayName).\(controller.language.fileExtension)"
        let proposed = SampleContent.documentsURL.appendingPathComponent(name)
        pendingDraftSave = (tab, text, proposed, completion)
        guard let window = view.window else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = SampleContent.documentsURL // default to the Chalk folder
        panel.canCreateDirectories = true
        activeSavePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.activeSavePanel = nil
            guard let pending = self.pendingDraftSave else { return }
            self.pendingDraftSave = nil
            guard response == .OK, let url = panel.url else {
                pending.completion(false) // tab stays a draft, buffer intact
                return
            }
            do {
                try Data(pending.text.utf8).write(to: url, options: .atomic)
            } catch {
                containerLog.error("draft save failed: \(DiagError(error), privacy: .public)")
                pending.completion(false)
                return
            }
            pending.tab.controller.bindDraft(to: url, writtenText: pending.text)
            pending.tab.url = url
            // Commit, or an unedited saved draft would be a preview a sidebar click replaces.
            pending.tab.isCommitted = true
            self.refreshTabBar() // chip retitles from "Untitled" to the filename
            self.onDraftSaved?(url)
            pending.completion(true)
        }
    }
}

/// The outline panel's resize handle: a horizontal-resize cursor and a drag
/// that reports its x travel.
final class ColumnResizeGrip: FlippedView {
    var onDragBegan: (() -> Void)?
    var onDragged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private var startX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDragged?(event.locationInWindow.x - startX)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}
