import AppKit
import WebKit
import ChalkKit
import os

/// File names are personal data, so they interpolate as `.private`.
private let containerLog = Logger(subsystem: "com.huleux.chalk", category: "editor-container")

/// The container's root view: flipped, clipping, and reporting appearance
/// flips to the controller.
final class EditorContainerView: ThemedView {
    var onAppearanceChange: (() -> Void)?

    override func refreshColors() { onAppearanceChange?() }
}

/// Hosts the open tabs in side-by-side tab groups and shows each group's tab in its pane. Each
/// tab owns its surface and document controller, so switching tabs preserves cursor, scroll and
/// undo. See docs/specs/2026-11-11-editor-groups-design.md.
final class EditorContainerViewController: NSViewController {
    /// The focused group: every command (save, compile, outline, PDF) acts on its tab.
    private var activeGroup = EditorGroup()
    /// Leading to trailing; never empty, and only the last group left can be empty.
    private lazy var groups: [EditorGroup] = [activeGroup]
    /// Every tab, leading group first: the window-wide view (dedupe, save-all, recovery).
    private var tabs: [Tab] { groups.flatMap(\.tabs) }
    /// The focused group's tab.
    private var activeTab: Tab? { activeGroup.activeTab }
    /// The tabs on screen, one per group.
    private var shownTabs: [Tab] { groups.compactMap(\.activeTab) }
    private func group(of tab: Tab) -> EditorGroup? { groups.first { $0.contains(tab) } }
    private func group(id: UUID) -> EditorGroup? { groups.first { $0.id == id } }
    /// How the column is shared between the groups (the pane host lays it out).
    private var groupsLayout: EditorGroupsLayout {
        get { contentView.layoutModel }
        set { contentView.layoutModel = newValue }
    }

    /// Reads the host window's own editing mode. A closure, not a stored copy: a copy goes stale
    /// when another window changes its mode. The default serves a container with no host (tests).
    var currentEditingMode: () -> EditingMode = { Preferences.editingMode }

    private let contentView = EditorPaneHostView()
    /// Watches clicks so one in an unfocused group's pane focuses it (`focusPane(under:)`).
    private var paneClickMonitor: Any?
    /// "No document open". Visibility is set explicitly by `refreshEmptyState()`, never by
    /// occlusion: a detached surface must not read as an empty window under a live chip.
    /// See docs/issues/2026-07-24-blank-editor-on-open.md.
    private var emptyStateView: NSView?

    /// Crash net for the no-autosave model: dirty buffers snapshot here and are offered back on
    /// the next launch. A graceful close or save clears its snapshot.
    private var recovery = RecoveryStore(directory: RecoveryStore.appDirectory)
    private var recoverySnapshotTimer: Timer?

    deinit {
        if let paneClickMonitor { NSEvent.removeMonitor(paneClickMonitor) }
        // The run loop retains the timer, so without this each closed dirty window leaks one.
        recoverySnapshotTimer?.invalidate()
        // A closed window's TeX runs would otherwise finish into nothing.
        compiler.cancelAll()
    }

    /// Edge pin swapped out while the content width is frozen for a sidebar
    /// slide; see `freezeContentWidth()`.
    private var contentLeading: NSLayoutConstraint?
    private var frozenContentWidth: NSLayoutConstraint?

    // MARK: Trailing slot

    /// The one frame on the column's trailing edge, whatever fills it: push, overlay, slide and
    /// the band's cut-out all act on it. Inside, the PDF sits left of the outline, so the source
    /// keeps its output beside it and the window's outline stays put when a tab's PDF comes and
    /// goes. Clips, so a panel entering or leaving slides in and out of the slot's own edges.
    /// See docs/specs/2026-09-04-outline-panel-design.md.
    private let trailingSlot = NSView()
    /// What the slot holds. Keeps its value while the slot is closed, so a slide-out is drawn.
    enum TrailingPanelContent { case outline, pdf }
    private(set) var trailingPanelContents: Set<TrailingPanelContent> = [.outline]
    /// The slot's visibility, whatever it holds.
    private(set) var isOutlinePanelVisible = false
    /// The persistent outline (⌘K).
    let outlinePanel = OutlinePanelViewController()
    /// The compiled PDF (⌥⌘P).
    let pdfPanel = PDFPanelViewController()
    /// This window's compiles (⌘R, Cmd+S) and SyncTeX.
    let compiler = CompileController()
    /// Only while the outline shows do surfaces push outline snapshots.
    private var isOutlineShowing: Bool { isShowing(.outline) }
    var isPDFPanelShowing: Bool { isShowing(.pdf) }
    func isShowing(_ content: TrailingPanelContent) -> Bool {
        isOutlinePanelVisible && trailingPanelContents.contains(content)
    }
    /// Fired after the slot opens, closes, resizes or changes mode, so the host can cut it out
    /// of the tab band's paint.
    var onOutlinePanelLayoutChanged: (() -> Void)?
    /// Straddles the slot's leading edge, in THIS view so it can extend over the editor's side.
    private let outlineResizeGrip = ColumnResizeGrip()
    /// Straddles the PDF/outline border while the slot holds both.
    private let innerResizeGrip = ColumnResizeGrip()
    /// Last frame announced through `onOutlinePanelLayoutChanged`, so only a layout pass that
    /// actually moved the slot re-cuts the band.
    private var lastAnnouncedOutlinePanelFrame: CGRect?
    /// The slot's frame in this container's view, nil while hidden.
    var outlinePanelFrame: CGRect? { isOutlinePanelVisible ? trailingSlot.frame : nil }
    private(set) var outlinePanelIsOverlay = false
    /// The slot's shown width: the panels' preferred widths fitted to the column (`fitSlotWidth`).
    private var slotWidthPin: NSLayoutConstraint?
    /// The slot's trailing pin: 0 when shown, +width when parked off-screen.
    private var slotTrailingPin: NSLayoutConstraint?
    private var outlineWidthPin: NSLayoutConstraint?
    /// 0 while the slot holds the outline, +width when it is parked past the slot's edge.
    private var outlineTrailingPin: NSLayoutConstraint?
    private var pdfWidthPin: NSLayoutConstraint?
    /// The widths the panels ask for (a drag, the stored preference), kept while a narrow column
    /// shows less, so a wider window gives them back.
    private var preferredOutlineWidth = Preferences.outlinePanelWidth
    private var preferredPDFWidth = Preferences.pdfPanelWidth
    /// The x, in this view, the slot must not start before: past it the band's chips lose their
    /// narrowest readable strip. Set by the host (`setSlotLeadingLimit`).
    private var slotLeadingLimit: CGFloat = 0
    private var contentTrailingToEdge: NSLayoutConstraint?
    private var contentTrailingToPanel: NSLayoutConstraint?

    /// Fired when the open tabs change so the host can redraw the strips, one per group.
    var onTabsChanged: (([TabGroupItem]) -> Void)?
    /// The groups' panes moved: the host realigns each group's strip over its pane.
    var onGroupFramesChanged: (() -> Void)?

    /// The ACTIVE tab's editor scroll offset (auto-hiding chrome).
    var onActiveEditorScroll: ((Double, Bool) -> Void)?

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
            if let glide, isShown(tab) {
                tab.surface.setChromeTopInset(inset, animatedOverSeconds: glide)
            } else {
                tab.surface.setChromeTopInset(inset)
            }
        }
        // The ramp fills the one-line pad between the chrome's floor and the resting first line:
        // solid down to the floor, clear at the resting line's box top, which sits above its ink.
        // Taller washes out resting text; shorter leaves too short a ramp to read as soft.
        chromeFadeHeight?.constant = CGFloat(inset)
        chromeFade.solidHeight = max(0, CGFloat(inset) - ChalkMetrics.editorRestingPad)
    }

    /// Auto-hide slides the band up by its height; the fade rides along so the band's floor and
    /// the ramp's start never part. Lifted, only the ramp shows, as a soft top edge.
    func setChromeFadeLift(_ lift: CGFloat) {
        chromeFadeTop?.constant = -lift
    }

    private let chromeFade = ChromeFadeView()
    private var chromeFadeHeight: NSLayoutConstraint?
    private var chromeFadeTop: NSLayoutConstraint?

    /// A draft was saved to `url` (first save picked a location), so the host
    /// can refresh the sidebar to show the new file.
    var onDraftSaved: ((URL) -> Void)?
    /// This window's Library roots, handed to every tab's controller (figure search bound).
    var libraryRootsProvider: () -> [URL] = { [] }

    /// In-flight draft save. Non-nil only while the save panel is up, which also guards against a
    /// second Cmd+S opening a second panel.
    private var pendingDraftSave: (tab: Tab, text: String, proposedURL: URL, completion: (Bool) -> Void)?
    private var activeSavePanel: NSSavePanel?


    /// Drag-reorder commit within a group: move tab `id` to strip position `index` (clamped) of
    /// its own group. Only the order changes; session restore serializes it.
    func moveTab(id: UUID, to index: Int) {
        guard let tab = tab(id: id), let group = group(of: tab) else { return }
        moveTab(id: id, toGroup: group.id, at: index)
    }

    /// Move tab `id` to position `index` of group `groupID` (a drop on another group's strip or
    /// editor). Leaving a group shows its next tab there; a group left empty closes. The moved tab
    /// is shown and focused in its new group.
    func moveTab(id: UUID, toGroup groupID: UUID, at index: Int) {
        guard let tab = tab(id: id), let source = group(of: tab), let target = group(id: groupID),
              let from = source.index(of: tab) else { return }
        if source === target {
            let to = max(0, min(index, source.tabs.count - 1))
            guard from != to else { return }
            source.tabs.remove(at: from)
            source.tabs.insert(tab, at: to)
            refreshTabBar()
            return
        }
        source.tabs.remove(at: from)
        target.tabs.insert(tab, at: max(0, min(index, target.tabs.count)))
        if source.activeTab === tab {
            if isOutlineShowing { tab.surface.setOutlineSubscription(false) }
            source.activeTab = nil
            tab.surface.view.removeFromSuperview()
            if source.tabs.isEmpty {
                removeGroup(source, refocusing: false)
            } else if let next = neighbor(in: source, at: from) {
                present(next, in: source)
            }
        }
        activate(tab)
    }

    /// Split: a new group beside group `groupID` (`trailing` puts it after), holding tab `id`.
    /// False, changing nothing, when no group fits at the minimum width (`ignoringWidth` is the
    /// matrix's way past that) or when the tab is its own group's only one: a tab is in one group,
    /// so splitting it off would leave an empty group behind.
    @discardableResult
    func splitTab(id: UUID, beside groupID: UUID, trailing: Bool, ignoringWidth: Bool = false) -> Bool {
        guard let tab = tab(id: id), let source = group(of: tab),
              let targetIndex = groups.firstIndex(where: { $0.id == groupID }),
              !(source === groups[targetIndex] && source.tabs.count < 2),
              ignoringWidth || canAddGroup else { return false }
        let newGroup = EditorGroup()
        let at = trailing ? targetIndex + 1 : targetIndex
        groups.insert(newGroup, at: at)
        groupsLayout = groupsLayout.inserting(at: at, splitting: targetIndex)
        applyPaneLayout()
        moveTab(id: id, toGroup: newGroup.id, at: 0)
        return true
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
        // The editor runs full-bleed under the transparent titlebar; the resting offset is done
        // web-side (`setChromeTopInset`).
        let trailingToEdge = contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        contentTrailingToEdge = trailingToEdge
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            leading,
            trailingToEdge,
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Feathers scrolled text out before it reaches the tab chips; sized by `setChromeTopInset`.
        chromeFade.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chromeFade)
        let fadeHeight = chromeFade.heightAnchor.constraint(equalToConstant: 0)
        chromeFadeHeight = fadeHeight
        let fadeTop = chromeFade.topAnchor.constraint(equalTo: view.topAnchor)
        chromeFadeTop = fadeTop
        NSLayoutConstraint.activate([
            fadeTop,
            chromeFade.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chromeFade.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fadeHeight,
        ])
        installTrailingSlot()
        installGroupControls()

        // Cross-window save sync. One observer per container, not per tab, so tab close needs no
        // teardown; selector-based observers detach on dealloc.
        NotificationCenter.default.addObserver(
            self, selector: #selector(documentDidSaveElsewhere(_:)),
            name: .chalkDocumentDidSave, object: nil)
    }

    private func refreshBackground() {
        view.chalkSetLayerBackground(.chalkEditorBackground)
    }

    private func installTrailingSlot() {
        let slot = trailingSlot
        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.wantsLayer = true
        slot.clipsToBounds = true
        // Above the chrome fade: the fade is for text, and over the panel it hid its top.
        view.addSubview(slot)

        let width = slot.widthAnchor.constraint(equalToConstant: Preferences.outlinePanelWidth)
        slotWidthPin = width
        let trailing = slot.trailingAnchor.constraint(
            equalTo: view.trailingAnchor,
            constant: isOutlinePanelVisible ? 0 : Preferences.outlinePanelWidth)
        slotTrailingPin = trailing
        contentTrailingToPanel = contentView.trailingAnchor.constraint(equalTo: slot.leadingAnchor)
        NSLayoutConstraint.activate([
            width, trailing,
            slot.topAnchor.constraint(equalTo: contentView.topAnchor),
            slot.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // The PDF first: it comes and goes from under the outline.
        pdfWidthPin = mount(pdfPanel, in: slot, width: preferredPDFWidth)
        outlineWidthPin = mount(outlinePanel, in: slot, width: preferredOutlineWidth)
        let outlineTrailing = outlinePanel.view.trailingAnchor.constraint(equalTo: slot.trailingAnchor)
        outlineTrailingPin = outlineTrailing
        NSLayoutConstraint.activate([
            outlineTrailing,
            // Holds with the PDF out of the slot too: it sits clipped past the leading edge,
            // ready to be uncovered.
            pdfPanel.view.trailingAnchor.constraint(equalTo: outlinePanel.view.leadingAnchor),
        ])
        outlinePanel.onJump = { [weak self] line in self?.revealLine(line) }
        wirePDFPanel()

        // The grips straddle their borders so a drag on the visible edge catches it from either
        // side, and each resizes the panel on its trailing side. They hide with the slot so a
        // parked slot leaves no phantom strip.
        install(outlineResizeGrip, on: slot.leadingAnchor) { [weak self] in
            self?.trailingPanelContents.contains(.pdf) == true ? .pdf : .outline
        }
        install(innerResizeGrip, on: outlinePanel.view.leadingAnchor) { .outline }

        settleSlotViews()
        fitSlotWidth()
        // A pre-load `setOutlinePanelVisible` ran this with nil constraints. The column may still
        // be unsized, so `viewDidLayout` re-evaluates it.
        updateOutlinePanelMode()
    }

    /// Add `child` to the slot at full height. Returns its width pin.
    private func mount(_ child: NSViewController, in slot: NSView, width: CGFloat) -> NSLayoutConstraint {
        addChild(child)
        let panel: NSView = child.view
        panel.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(panel)
        let pin = panel.widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([
            pin,
            panel.topAnchor.constraint(equalTo: slot.topAnchor),
            panel.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
        ])
        return pin
    }

    private func wirePDFPanel() {
        pdfPanel.onCompile = { [weak self] in self?.compileActive() }
        pdfPanel.onSyncClick = { [weak self] page, point in self?.reverseSync(page: page, point: point) }
        pdfPanel.onIssue = { [weak self] issue in self?.jump(to: issue) }
        compiler.libraryRootsProvider = { [weak self] in self?.libraryRootsProvider() ?? [] }
        compiler.onStateChange = { [weak self] root in
            guard let self, self.isPDFPanelShowing, self.pdfPanelRoot == root else { return }
            self.pdfPanel.show(root: root, state: self.compiler.states[root])
        }
    }

    /// `panel` is read when a drag begins: what the slot's edge resizes depends on what it holds.
    private func install(_ grip: ColumnResizeGrip, on edge: NSLayoutXAxisAnchor,
                         resizing panel: @escaping () -> TrailingPanelContent) {
        grip.showsHoverLine = true
        grip.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grip)
        NSLayoutConstraint.activate([
            grip.centerXAnchor.constraint(equalTo: edge),
            grip.widthAnchor.constraint(equalToConstant: 12),
            grip.topAnchor.constraint(equalTo: trailingSlot.topAnchor),
            grip.bottomAnchor.constraint(equalTo: trailingSlot.bottomAnchor),
        ])
        var dragged = TrailingPanelContent.outline
        var startWidth: CGFloat = 0
        grip.onDragBegan = { [weak self] in
            guard let self else { return }
            dragged = panel()
            startWidth = self.shownWidth(of: dragged)
        }
        grip.onDragged = { [weak self] dx in
            self?.setPanelWidth(dragged, startWidth - dx, persist: false)
        }
        grip.onDragEnded = { [weak self] in
            guard let self else { return }
            self.setPanelWidth(dragged, self.shownWidth(of: dragged), persist: true)
        }
    }

    private func shownWidth(of content: TrailingPanelContent) -> CGFloat {
        (content == .pdf ? pdfWidthPin : outlineWidthPin)?.constant ?? 0
    }

    /// Open or close the slot: ⌘K's outline, the zen close, session restore. Opening puts the
    /// outline in it; closing also takes the active tab's PDF down.
    func setOutlinePanelVisible(_ visible: Bool, animated: Bool) {
        isOutlineWanted = visible
        if !visible { activeTab?.showsPDF = false }
        applySlot(animated: animated)
    }

    /// Show or hide the slot as it stands. The webview reflows inside the container rather than
    /// sliding under chrome, so a plain constraint animation is enough (no WebPaintGate).
    private func setSlotVisible(_ visible: Bool, animated: Bool) {
        guard visible != isOutlinePanelVisible else { return }
        isOutlinePanelVisible = visible
        if visible {
            revealSlotViews()
            updateOutlinePanelMode()
            // Place the panel at its off-screen start before the slide: a
            // hidden view keeps a stale frame, and un-hiding it inside the
            // animated pass showed that frame for one frame at the top
            // trailing corner before the slide began.
            view.layoutSubtreeIfNeeded()
            seed(trailingPanelContents)
        } else {
            if trailingPanelContents.contains(.outline) { activeTab?.surface.setOutlineSubscription(false) }
            outlinePanelIsOverlay = false
            contentTrailingToPanel?.isActive = false
            contentTrailingToEdge?.isActive = true
        }
        slotTrailingPin?.constant = visible ? 0 : (slotWidthPin?.constant ?? 0)
        runSlotLayout(animated: animated)
    }

    /// Run the pending slot constraints on the sidebar's clock. Reads the live flags at the end,
    /// not the caller's: with a fast close-then-open, a hide's completion fires after the reopen.
    private func runSlotLayout(animated: Bool) {
        let finish = { [weak self] in
            guard let self else { return }
            self.settleSlotViews()
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

    /// Un-hide what the slot now holds. A panel leaving stays up until `settleSlotViews`.
    private func revealSlotViews() {
        trailingSlot.isHidden = false
        outlineResizeGrip.isHidden = false
        if trailingPanelContents.contains(.outline) { outlinePanel.view.isHidden = false }
        if trailingPanelContents.contains(.pdf) { pdfPanel.view.isHidden = false }
    }

    /// Hide all the resting slot does not show.
    private func settleSlotViews() {
        let showing = isOutlinePanelVisible ? trailingPanelContents : []
        trailingSlot.isHidden = showing.isEmpty
        outlineResizeGrip.isHidden = showing.isEmpty
        innerResizeGrip.isHidden = showing.count < 2
        outlinePanel.view.isHidden = !showing.contains(.outline)
        pdfPanel.view.isHidden = !showing.contains(.pdf)
    }

    /// Push while the column can spare the width; overlay once the text
    /// would drop below `ChalkMetrics.outlinePanelPushMinimumEditorWidth`.
    /// Re-evaluated on every layout pass so a window resize flips it.
    private func updateOutlinePanelMode() {
        // Mid-slide the content is trailing-anchored at a frozen width: swapping the trailing pin
        // would jump it sideways. `unfreezeContentWidth` re-evaluates after the reflow.
        guard frozenContentWidth == nil else { return }
        guard isOutlinePanelVisible, let width = slotWidthPin?.constant else { return }
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

    /// Fill `contents` from the active tab.
    private func seed(_ contents: Set<TrailingPanelContent>) {
        if contents.contains(.outline) {
            seedOutlinePanel()
            activeTab?.surface.setOutlineSubscription(true)
        }
        if contents.contains(.pdf) {
            refreshPDFPanel()
        }
    }

    /// The window wants the outline (⌘K).
    private(set) var isOutlineWanted = false

    /// What the slot should hold for the active tab: its PDF when it asked for one, and the
    /// outline when the window wants it. Zen keeps it closed, even on a tab switch.
    private var desiredSlot: Set<TrailingPanelContent> {
        if currentEditingMode() == .zen { return [] }
        var contents: Set<TrailingPanelContent> = []
        if activeTab?.showsPDF == true { contents.insert(.pdf) }
        if isOutlineWanted { contents.insert(.outline) }
        return contents
    }

    /// Bring the slot in line with `desiredSlot`. `seeding` is what to refill in an open slot,
    /// nil for all of it, as a tab switch needs: refilling the PDF reads it from disk.
    private func applySlot(animated: Bool, seeding: Set<TrailingPanelContent>? = nil) {
        let contents = desiredSlot
        if contents.isEmpty {
            setSlotVisible(false, animated: animated)
        } else {
            presentSlot(contents, animated: animated, seeding: seeding ?? contents)
        }
    }

    /// Show `content` beside whatever the slot already holds: ⌥⌘P and Compile mark the active
    /// tab as showing its PDF, ⌘K puts the window's outline up.
    func showTrailingPanel(_ content: TrailingPanelContent, animated: Bool) {
        setWanted(content, true, animated: animated)
    }

    /// ⌘K / ⌥⌘P: take `content` down when the slot shows it, else show it.
    func toggleTrailingPanel(_ content: TrailingPanelContent, animated: Bool) {
        setWanted(content, !isShowing(content), animated: animated)
    }

    private func setWanted(_ content: TrailingPanelContent, _ wanted: Bool, animated: Bool) {
        switch content {
        case .pdf: activeTab?.showsPDF = wanted
        case .outline: isOutlineWanted = wanted
        }
        applySlot(animated: animated, seeding: wanted ? [content] : [])
    }

    /// Slide the slot in with `contents`, or, when it is open, slide the panels that change in
    /// or out of its edges.
    private func presentSlot(_ contents: Set<TrailingPanelContent>, animated: Bool,
                             seeding: Set<TrailingPanelContent>) {
        if isOutlinePanelVisible, trailingPanelContents == contents {
            seed(seeding)
            return
        }
        if isOutlineShowing, !contents.contains(.outline) {
            activeTab?.surface.setOutlineSubscription(false)
        }
        trailingPanelContents = contents
        guard isOutlinePanelVisible else {
            fitSlotWidth()
            setSlotVisible(true, animated: animated)
            return
        }
        // At its start before the slide, as in `setSlotVisible`.
        revealSlotViews()
        view.layoutSubtreeIfNeeded()
        seed(seeding)
        fitSlotWidth()
        updateOutlinePanelMode()
        runSlotLayout(animated: animated)
    }

    /// Fill the panel from the active tab before the first push lands.
    private func seedOutlinePanel() {
        outlinePanel.setDocumentName(activeTab?.displayName ?? "",
                                     key: activeTab.map { $0.url?.path ?? $0.id.uuidString })
        guard let tab = activeTab else {
            outlinePanel.setSnapshot(.empty)
            return
        }
        tab.surface.fetchOutline { [weak self, weak tab] snapshot in
            guard let self, let tab, self.activeTab === tab, self.isOutlineShowing else { return }
            self.outlinePanel.setSnapshot(snapshot ?? .empty)
        }
    }

    private static func widthRange(of content: TrailingPanelContent) -> ClosedRange<CGFloat> {
        content == .pdf ? Preferences.pdfPanelWidthRange : Preferences.sidebarWidthRange
    }

    func setPanelWidth(_ content: TrailingPanelContent, _ proposed: CGFloat, persist: Bool) {
        let range = Self.widthRange(of: content)
        let clamped = min(range.upperBound, max(range.lowerBound, proposed))
        switch content {
        case .outline:
            preferredOutlineWidth = clamped
            if persist { Preferences.outlinePanelWidth = clamped }
        case .pdf:
            preferredPDFWidth = clamped
            if persist { Preferences.pdfPanelWidth = clamped }
        }
        fitSlotWidth()
        updateOutlinePanelMode()
        if isOutlinePanelVisible {
            view.layoutSubtreeIfNeeded()
            onOutlinePanelLayoutChanged?()
        }
    }

    /// Show the panels' preferred widths, or as much of them as the column has past
    /// `slotLeadingLimit`. Wider, the slot overhangs the Library and leaves the band's chips no
    /// room. Never below the contents' minimum, which an early layout pass's column and a tiny
    /// window both undercut: the panels' own chrome needs it, and the band survives the overhang
    /// (`HeaderBarView.stripTrailing`). Two panels also leave the editor its push width while
    /// they can, or one ⌘K would throw the text under the slot. The PDF gives way first.
    private func fitSlotWidth() {
        guard let slotPin = slotWidthPin else { return }
        let hasOutline = trailingPanelContents.contains(.outline)
        let hasPDF = trailingPanelContents.contains(.pdf)
        let column = view.bounds.width
        var room = column - slotLeadingLimit
        if hasOutline, hasPDF { room = min(room, column - ChalkMetrics.outlinePanelPushMinimumEditorWidth) }
        let outlineMinimum = hasOutline ? Self.widthRange(of: .outline).lowerBound : 0
        let pdfMinimum = hasPDF ? Self.widthRange(of: .pdf).lowerBound : 0
        let wanted = (hasOutline ? preferredOutlineWidth : 0) + (hasPDF ? preferredPDFWidth : 0)
        let fitted = max(outlineMinimum + pdfMinimum, min(wanted, room))

        // A panel out of the slot keeps its preferred width for its slide.
        let outline = hasOutline ? min(preferredOutlineWidth, fitted - pdfMinimum) : preferredOutlineWidth
        let pdf = hasPDF ? fitted - (hasOutline ? outline : 0) : preferredPDFWidth

        Self.set(outlineWidthPin, to: outline)
        Self.set(pdfWidthPin, to: pdf)
        Self.set(outlineTrailingPin, to: hasOutline ? 0 : outline)
        Self.set(slotPin, to: fitted)
        if !isOutlinePanelVisible { Self.set(slotTrailingPin, to: fitted) }
    }

    /// Layout re-fits on every pass, so a write that changes nothing must not dirty it again.
    private static func set(_ pin: NSLayoutConstraint?, to constant: CGFloat) {
        guard let pin, abs(pin.constant - constant) > 0.5 else { return }
        pin.constant = constant
    }

    /// The host's limit for the slot's leading edge, in this view (`HeaderBarView.stripReadableExtent`).
    func setSlotLeadingLimit(_ x: CGFloat) {
        guard abs(x - slotLeadingLimit) > 0.5 else { return }
        slotLeadingLimit = x
        // Mid-slide a pushed column is pinned to the slot at a frozen width: resizing the slot
        // would jump it sideways. `unfreezeContentWidth` refits.
        guard frozenContentWidth == nil else { return }
        fitSlotWidth()
        updateOutlinePanelMode()
    }

    /// A DocumentController (possibly in another window) saved `url`. Reuses the external-change
    /// path, which never overwrites local edits. The posting controller is already current.
    @objc private func documentDidSaveElsewhere(_ note: Notification) {
        guard let url = note.userInfo?[ChalkNotificationKey.url] as? URL else { return }
        let sender = note.object as? DocumentController
        let identity = url.fileIdentity
        for tab in tabs {
            guard tab.fileIdentity == identity, tab.controller !== sender else { continue }
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
        // The slide may have narrowed the column past the slot and crossed the push/overlay
        // threshold while frozen.
        fitSlotWidth()
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
    #endif

    /// The active tab's surface, for the covers a transition installs over it.
    var activeSurface: EditorSurface? { activeTab?.surface }

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
        let line = "layout content=\(contentView.frame) active=\(activeTab?.surface.view.frame ?? .zero) panelHidden=\(trailingSlot.isHidden) panel=\(trailingSlot.frame) frozen=\(frozenContentWidth != nil)"
        if line != lastTracedLayout { lastTracedLayout = line; DebugTrace.log(line) }
        #endif
        syncActiveSurfaceAppearance()
        if frozenContentWidth == nil { fitSlotWidth() }
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

    /// What the shown surfaces were last told, so a resync can tell "already agrees" from "never
    /// heard". Reset on activate.
    private var pushedDark: Bool?
    private var pushedTheme: ChalkTheme?

    /// Set when the host runs the covered appearance transition and pushes the theme itself
    /// (docs/motion.md "Appearance"); the appearance hook then stands down, since it would flip
    /// the page outside the cover. Standalone containers (tests) keep the hook.
    var hostOwnsAppearanceTransitions = false

    /// The orchestrator's push (the shown surfaces only; the rest are dressed on activate).
    func pushAppearance(dark: Bool, theme: ChalkTheme) {
        pushedDark = dark
        pushedTheme = theme
        for tab in shownTabs {
            pushAppearance(to: tab.surface, dark: dark, theme: theme)
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
        if let existing = tab(showing: url) {
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
    private func adopt(_ tab: Tab, into group: EditorGroup? = nil) {
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
        surface.onScroll = { [weak self, weak tab] y, wheel in
            guard let self, let tab, self.activeTab === tab else { return }
            self.onActiveEditorScroll?(y, wheel)
        }
        surface.onOutline = { [weak self, weak tab] snapshot in
            guard let self, let tab, self.activeTab === tab, self.isOutlineShowing else { return }
            self.outlinePanel.setSnapshot(snapshot)
        }
        (group ?? activeGroup).tabs.append(tab)
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

    /// Apply an editor zoom to every open tab.
    func setFontScale(_ scale: Double) {
        tabs.forEach { $0.surface.setFontScale(scale) }
    }

    /// The last measure pushed, recorded only for tests. `adopt` seeds new tabs from `Preferences`.
    private(set) var lastPushedMeasure: Double?

    /// Apply the text column width (Settings slider) to every open tab.
    func setMeasure(_ px: Double) {
        lastPushedMeasure = px
        for tab in tabs { tab.surface.setMeasure(px) }
    }

    /// Apply the interline spacing (Settings slider) to every open tab.
    func setLineHeight(_ multiplier: Double) {
        for tab in tabs { tab.surface.setLineHeight(multiplier) }
    }

    /// Apply the wrapped-prose alignment (Settings) to every open tab.
    func setTextAlign(_ alignment: EditorTextAlignment) {
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

    /// The groups as journal records, file-backed tabs only, bookmarks included (drafts die with
    /// the window, so an active draft's index is nil and a drafts-only group is dropped by
    /// `WindowSession`), and the focused group's index into them.
    func sessionGroups() -> (groups: [WindowSession.GroupRecord], activeGroupIndex: Int?) {
        let fractions = groupsLayout.fitted(toCount: groups.count).fractions
        let records = groups.enumerated().map { i, group in
            let fileTabs = group.tabs.filter { $0.url != nil }
            return WindowSession.GroupRecord(
                tabs: fileTabs.compactMap { $0.sessionRecord() },
                activeIndex: fileTabs.firstIndex { $0 === group.activeTab },
                fraction: Double(fractions[i]))
        }
        return (records, groups.firstIndex { $0 === activeGroup })
    }

    /// Session restore: rebuild the groups. Each entry is one group's files in strip order (the
    /// ones that are still readable), the one it showed, and its width share. Tabs are opened
    /// dormant; only each group's shown tab boots a web view.
    func restoreGroups(_ records: [(urls: [URL], activeIndex: Int?, fraction: Double)], activeGroupIndex: Int?) {
        loadViewIfNeeded()
        var built: [(group: EditorGroup, active: Int?, fraction: CGFloat)] = []
        var focused: EditorGroup?
        for (i, record) in records.enumerated() {
            // The first group fills the group already there (it may hold a launch tab).
            let group = built.isEmpty ? activeGroup : EditorGroup()
            if group !== activeGroup { groups.append(group) }
            for url in record.urls where tab(showing: url) == nil {
                let tab = Tab(url: url)
                adopt(tab, into: group)
                tab.controller.open(url: url)
            }
            built.append((group, record.activeIndex, CGFloat(record.fraction)))
            if i == activeGroupIndex { focused = group }
        }
        // A group whose files are all gone is not restored.
        built.removeAll { entry in
            guard entry.group.tabs.isEmpty, groups.count > 1 else { return false }
            groups.removeAll { $0 === entry.group }
            return true
        }
        groupsLayout = EditorGroupsLayout(fractions: built.map(\.fraction)).fitted(toCount: groups.count)
        applyPaneLayout()
        for entry in built {
            let index = entry.active.flatMap { entry.group.tabs.indices.contains($0) ? $0 : nil } ?? 0
            guard entry.group.tabs.indices.contains(index) else { continue }
            present(entry.group.tabs[index], in: entry.group)
        }
        activeGroup = focused.flatMap { f in groups.first { $0 === f } } ?? groups[0]
        if let tab = activeTab { activate(tab) } else { refreshTabBar() }
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
                if let existing = tab(showing: url) {
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
        var live: [String: String] = [:]
        for tab in tabs {
            let id = tab.id.uuidString
            if tab.isDirty {
                let text = tab.controller.currentText
                live[id] = text
                // Unchanged since the last tick: the file on disk already says this.
                if lastSnapshotText[id] != text { writes.append((id, text, tab.url)) }
            } else if !tab.controller.hasUnappliedRecovery {
                // A failed restore-open reads clean, but its snapshot is the only copy of the
                // crash edits.
                clears.append(id)
            }
        }
        lastSnapshotText = live
        guard !writes.isEmpty || !clears.isEmpty else { return }
        let store = recovery
        recoveryQueue.async {
            for w in writes { Self.writeSnapshot(to: store, id: w.id, text: w.text, fileURL: w.fileURL) }
            for id in clears { store.clear(id: id) }
        }
    }

    /// What the last snapshot pass wrote per dirty tab, so an idle dirty document is not
    /// rewritten every ten seconds.
    private var lastSnapshotText: [String: String] = [:]

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
    /// Every tab's strip snapshot, leading group first, as the next refreshTabBar() would publish
    /// them (unit tests). `isActive` is per group: each group's shown tab.
    var tabItemsForTesting: [TabItem] { makeTabItems().flatMap(\.tabs) }
    var groupItemsForTesting: [TabGroupItem] { makeTabItems() }

    /// Every URL whose open failure reached the user, so a test can wait for the failure itself.
    private(set) var openFailuresForTesting: [URL] = []

    /// The file a draft save proposes to the save panel, while the save is pending.
    var pendingDraftSaveFileForTesting: URL? { pendingDraftSave?.proposedURL }

    var isEmptyStateVisibleForTesting: Bool {
        guard let emptyStateView else { return false }
        return !emptyStateView.isHidden
    }

    var contentViewFrameForTesting: CGRect { contentView.frame }
    /// Each group's pane, leading first, in this view's coordinates.
    var paneFramesForTesting: [CGRect] {
        contentView.panes.map { view.convert($0.frame, from: contentView) }
    }
    /// The seam grips between neighbouring groups, leading first, in this view's coordinates.
    var groupDividerFramesForTesting: [CGRect] {
        contentView.grips.map { view.convert($0.frame, from: contentView) }
    }
    /// The focused tab's position in the window-wide (leading group first) order.
    var activeTabIndexForTesting: Int? { tabs.firstIndex { $0 === activeTab } }
    var focusedGroupIndexForTesting: Int? { groups.firstIndex { $0 === activeGroup } }
    /// Activate by window-wide position (leading group first); ignores out-of-range.
    func activateTabForTesting(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activate(tabs[index])
    }
    /// Each group's shown tab as a window-wide index.
    var groupActiveTabIndicesForTesting: [Int?] {
        let all = tabs
        return groups.map { group in group.activeTab.flatMap { tab in all.firstIndex { $0 === tab } } }
    }
    /// The group whose pane hosts the tab's surface; nil when detached.
    func paneGroupIndexForTesting(tabAt index: Int) -> Int? {
        let all = tabs
        guard all.indices.contains(index) else { return nil }
        let superview = all[index].surface.view.superview
        return groups.firstIndex { $0.pane === superview }
    }
    /// The click path's focus change, without synthesizing an event.
    func focusPaneForTesting(group index: Int) {
        guard groups.indices.contains(index), let tab = groups[index].activeTab else { return }
        activate(tab, focusingEditor: false)
    }
    func dragGroupDividerForTesting(seam: Int = 0, by dx: CGFloat) {
        guard contentView.grips.indices.contains(seam) else { return }
        let grip = contentView.grips[seam]
        grip.onDragBegan?()
        grip.onDragged?(dx)
        grip.onDragEnded?()
        contentView.layoutSubtreeIfNeeded()
    }
    var groupFractionsForTesting: [CGFloat] { groupsLayout.fractions }
    /// The drop indicator's rect in the pane host, nil while hidden.
    var dropIndicatorForTesting: CGRect? { contentView.dropOverlay.shownRect }

    var outlinePanelWidthForTesting: CGFloat { slotWidthPin?.constant ?? 0 }
    /// One panel's frame in this container's view, for the slot's inner layout.
    func panelFrameForTesting(_ content: TrailingPanelContent) -> CGRect {
        let panel: NSView = content == .pdf ? pdfPanel.view : outlinePanel.view
        return view.convert(panel.frame, from: trailingSlot)
    }
    var isInnerResizeGripHiddenForTesting: Bool { innerResizeGrip.isHidden }
    var outlineResizeGripFrameForTesting: CGRect { outlineResizeGrip.frame }
    var outlineResizeGripIsHiddenForTesting: Bool { outlineResizeGrip.isHidden }
    var isOutlinePanelAboveChromeFadeForTesting: Bool {
        guard let panel = view.subviews.firstIndex(of: trailingSlot),
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

    /// Tab dedupe by file identity: a raw `URL ==` misses aliases such as `/private/var/…`
    /// versus `/var/…`, which would open one file in two tabs.
    private func tab(showing url: URL) -> Tab? {
        let identity = url.fileIdentity
        return tabs.first { $0.fileIdentity == identity }
    }

    /// Show `tab` in its group and focus that group. A tab already shown in another group only
    /// moves focus: both surfaces stay where they are, with no install and no cross-fade.
    private func activate(_ tab: Tab, focusingEditor: Bool = true) {
        guard let group = group(of: tab) else { return }
        let outgoingFocus = activeTab
        if group !== activeGroup {
            if isOutlineShowing { outgoingFocus?.surface.setOutlineSubscription(false) }
            activeGroup = group
        }
        if group.activeTab !== tab {
            let outgoingSurface = group.activeTab?.surface
            if isOutlineShowing { group.activeTab?.surface.setOutlineSubscription(false) }
            group.activeTab = tab
            dressAndInstall(tab)
            // Each tab keeps its own PDF; the outline follows the window.
            applySlot(animated: false)
            if let outgoingSurface, outgoingSurface.view !== tab.surface.view {
                crossFade(from: outgoingSurface, to: tab.surface)
            }
        } else {
            // Re-activating a shown tab still installs, so a detached surface is repaired.
            ensureInstalled(tab)
            // The outline and the PDF follow focus.
            if outgoingFocus !== tab { applySlot(animated: false) }
        }
        refreshEmptyState()
        refreshTabBar()
        if focusingEditor { focusEditorNextTurn(tab) }
    }

    /// Show `tab` in `group` without moving focus: a group that lost its shown tab to a close or
    /// a move, or a restored group. Dressed before install, like an activated one.
    private func present(_ tab: Tab, in group: EditorGroup) {
        guard group.contains(tab), group.activeTab !== tab else { return }
        group.activeTab?.surface.view.removeFromSuperview()
        group.activeTab = tab
        dressAndInstall(tab)
        refreshTabBar()
    }

    /// Dress a surface about to be shown (appearance, chrome-top) BEFORE install, so it never
    /// flashes a stale theme or band height (docs/motion.md "Tab switch").
    private func dressAndInstall(_ tab: Tab) {
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
    }

    /// Every activation focuses the editor, a turn later so the triggering control (tab chip,
    /// Library row) has finished its click and can't pull first responder back.
    private func focusEditorNextTurn(_ tab: Tab) {
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
        // Both live in the focused group's pane; the fade never touches another group's.
        guard incoming.chalkMotionAllowed, !motionIsInstant,
              let pane = incoming.superview, outgoing.superview === pane else {
            DebugTrace.log("tab cross-fade: instant swap")
            outgoing.removeFromSuperview()
            return
        }
        pane.addSubview(incoming, positioned: .below, relativeTo: outgoing)
        var swapped = false
        let swap: (NSImage?) -> Void = { [weak self] image in
            guard !swapped, let self else { return }
            swapped = true
            // A rapid switch can show `outgoing` again (active, or in another group's pane)
            // before its bitmap lands: never remove it then, and never paint a stale bitmap over it.
            guard !self.isShown(outgoing) else { return }
            guard let image else {
                outgoing.removeFromSuperview()
                return
            }
            let bitmap = NSImageView.chalkSnapshot(image, frame: outgoing.frame)
            pane.addSubview(bitmap, positioned: .above, relativeTo: nil)
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

    /// The single surface-install site: each group's shown tab into that group's pane. A surface
    /// in the wrong pane moves. Removal drops the edge constraints, so each install activates a
    /// fresh set.
    private func ensureInstalled(_ tab: Tab) {
        guard let group = group(of: tab), group.activeTab === tab else { return }
        tab.surface.bootIfNeeded() // dormant until first shown (fd bound)
        let pane = group.pane
        let editorView = tab.surface.view
        guard editorView.superview !== pane else { return }
        editorView.removeFromSuperview()
        editorView.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(editorView)
        NSLayoutConstraint.activate([
            editorView.topAnchor.constraint(equalTo: pane.topAnchor),
            editorView.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            editorView.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
    }

    private func isShown(_ tab: Tab) -> Bool { groups.contains { $0.activeTab === tab } }

    private func isShown(_ surfaceView: NSView) -> Bool {
        groups.contains { $0.activeTab?.surface.view === surfaceView }
    }

    private func tab(id: UUID) -> Tab? { tabs.first { $0.id == id } }

    /// Tab strip callbacks.
    func activate(id: UUID) {
        if let tab = tab(id: id) { activate(tab) }
    }

    private func close(_ tab: Tab) {
        if tab.isDirty {
            confirmClose(tab)
        } else {
            performClose(tab)
        }
    }

    func closeTab(id: UUID) {
        if let tab = tabs.first(where: { $0.id == id }) { close(tab) }
    }

    private func performClose(_ tab: Tab) {
        // A deliberate close must not resurrect at the next launch, unless the tab still holds
        // unapplied crash-recovered text: that snapshot is the only copy, so the next drain retries.
        if !tab.controller.hasUnappliedRecovery {
            clearSnapshotQueued(id: tab.id.uuidString)
        }
        tab.surface.view.removeFromSuperview()
        tab.surface.teardown()
        tab.controller.close()
        guard let group = group(of: tab), let index = group.index(of: tab) else { return }
        let wasShown = group.activeTab === tab
        group.tabs.remove(at: index)
        if wasShown { group.activeTab = nil }

        // VS Code's closeEmptyGroups: a group's last tab takes the group with it.
        if group.tabs.isEmpty && groups.count > 1 {
            removeGroup(group, refocusing: true)
        } else if wasShown {
            if let next = neighbor(in: group, at: index) {
                if group === activeGroup { activate(next) } else { present(next, in: group) }
            } else {
                applySlot(animated: false)
                refreshEmptyState()
                refreshTabBar()
            }
        } else {
            refreshTabBar()
        }
    }

    /// The tab of `group` nearest strip position `index` (a closed or moved tab's).
    private func neighbor(in group: EditorGroup, at index: Int) -> Tab? {
        guard !group.tabs.isEmpty else { return nil }
        return group.tabs[min(index, group.tabs.count - 1)]
    }

    /// Close `group` (empty, or emptied by a join) and give its width to its leading neighbour.
    /// `refocusing` moves focus to the neighbour when the closed group had it; a caller that is
    /// about to focus something itself passes false.
    private func removeGroup(_ group: EditorGroup, refocusing: Bool) {
        guard groups.count > 1, let index = groups.firstIndex(where: { $0 === group }) else { return }
        groups.remove(at: index)
        groupsLayout = groupsLayout.removing(at: index)
        group.activeTab?.surface.view.removeFromSuperview()
        applyPaneLayout()
        if group === activeGroup {
            activeGroup = groups[max(0, index - 1)]
            if refocusing {
                applySlot(animated: false)
                refreshEmptyState()
                if let tab = activeTab { focusEditorNextTurn(tab) }
            }
        }
        refreshTabBar()
    }

    /// ⌃Tab cycles the focused group's tabs (VS Code's next editor in group).
    private func cycle(_ delta: Int) {
        let ring = activeGroup.tabs
        guard let active = activeTab, ring.count > 1,
              let i = ring.firstIndex(where: { $0 === active }) else { return }
        activate(ring[(i + delta + ring.count) % ring.count])
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

    private func makeTabItems() -> [TabGroupItem] {
        // The "folder/" prefix shows only where another open tab, in any group, has the same
        // filename.
        let all = tabs
        let needsPrefix = TabStripPolicy.needsFolderPrefix(names: all.map(\.displayName))
        var flat = 0
        return groups.map { group in
            let items = group.tabs.map { tab -> TabItem in
                defer { flat += 1 }
                return TabItem(id: tab.id, name: tab.displayName, isDirty: tab.isDirty,
                               isActive: tab === group.activeTab,
                               // Preview: a file-backed tab not yet committed (what a sidebar
                               // click reuses).
                               isPreview: tab.url != nil && !tab.isCommitted,
                               folder: needsPrefix[flat]
                                   ? tab.url.flatMap(TabStripPolicy.folderPrefix(for:))
                                   : nil)
            }
            return TabGroupItem(id: group.id, tabs: items, isFocused: group === activeGroup)
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
        contentView.addSubview(stack, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        emptyStateView = stack
        refreshEmptyState()
    }
}

// MARK: - Tab groups

extension EditorContainerViewController {
    var groupCount: Int { groups.count }
    /// The surfaces on screen besides the focused one, for the covers a transition installs over
    /// the panes.
    var otherShownSurfaces: [EditorSurface] {
        groups.filter { $0 !== activeGroup }.compactMap { $0.activeTab?.surface }
    }
    /// Every pane, for a cover's bitmap of what is on screen.
    var paneHostView: NSView { contentView }
    /// Each group's id and pane frame in `view`'s coordinates, leading first, for the strips the
    /// host aligns over them.
    var groupFrames: [(id: UUID, frame: CGRect)] {
        groups.map { ($0.id, view.convert($0.pane.frame, from: contentView)) }
    }
    /// Whether one more group fits beside these at the minimum width.
    var canAddGroup: Bool {
        groupsLayout.canInsert(columnWidth: contentView.bounds.width, minimum: ChalkMetrics.groupMinimumWidth)
    }

    /// ⌘\ (Split Editor Right): the focused tab moves into a new group to the right of its own,
    /// under `splitTab`'s rules.
    var canSplitRight: Bool { activeTab != nil && activeGroup.tabs.count > 1 && canAddGroup }

    @discardableResult
    func splitRight(ignoringWidth: Bool = false) -> Bool {
        guard let tab = activeTab else { return false }
        return splitTab(id: tab.id, beside: activeGroup.id, trailing: true, ignoringWidth: ignoringWidth)
    }

    /// ⌥-click and the tab menu's "Move to Right Group": into the group to the right of the tab's
    /// own, made when there is none (VS Code's open to the side).
    func moveToNeighborGroup(id: UUID, trailing: Bool) {
        guard let tab = tab(id: id), let source = group(of: tab),
              let index = groups.firstIndex(where: { $0 === source }) else { return }
        let neighbor = index + (trailing ? 1 : -1)
        if groups.indices.contains(neighbor) {
            moveTab(id: id, toGroup: groups[neighbor].id, at: groups[neighbor].tabs.count)
        } else {
            splitTab(id: id, beside: source.id, trailing: trailing)
        }
    }

    /// ⌘1…⌘9: focus group `index` (0-based); false when there is no such group.
    @discardableResult
    func focusGroup(at index: Int) -> Bool {
        guard groups.indices.contains(index), let tab = groups[index].activeTab else { return false }
        activate(tab)
        return true
    }

    /// ⌥⌘\: focus the next group, wrapping.
    func focusNextGroup() {
        guard groups.count > 1, let index = groups.firstIndex(where: { $0 === activeGroup }) else { return }
        focusGroup(at: (index + 1) % groups.count)
    }

    /// Focus group `id` (its row's "+").
    func focusGroup(id: UUID) {
        if let tab = group(id: id)?.activeTab { activate(tab) }
    }

    /// Join All Groups: every tab into the focused group, in strip order, leading group first.
    func joinAllGroups() {
        guard groups.count > 1 else { return }
        let all = tabs
        for group in groups where group !== activeGroup {
            group.activeTab?.surface.view.removeFromSuperview()
            group.activeTab = nil
        }
        activeGroup.tabs = all
        groups = [activeGroup]
        groupsLayout = .single
        applyPaneLayout()
        refreshTabBar()
        if let tab = activeTab { focusEditorNextTurn(tab) }
    }

    /// Close Group: close every tab of group `id` (each unsaved one asks first). The shown tab
    /// goes last, so no closing tab is shown (and its web view booted) on the way out.
    func closeGroup(id: UUID) {
        guard let group = group(id: id) else { return }
        for tab in group.tabs where tab !== group.activeTab { close(tab) }
        if let shown = group.activeTab { close(shown) }
    }

    /// The pane host follows the model: one pane per group.
    private func applyPaneLayout() {
        contentView.setPanes(groups.map(\.pane))
        contentView.layoutSubtreeIfNeeded()
    }

    private func installGroupControls() {
        contentView.onPaneFramesChanged = { [weak self] in self?.onGroupFramesChanged?() }
        applyPaneLayout()
        paneClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.focusPane(under: event)
            return event
        }
    }

    /// A click in an unfocused group's pane focuses that group. Observed, never consumed: the
    /// click still lands in the page and places the caret, so the editor is not refocused on
    /// top of it.
    private func focusPane(under event: NSEvent) {
        guard groups.count > 1, let window = view.window, event.window === window,
              let root = window.contentView, let frame = root.superview else { return }
        // A hit test, not a frame check: the tab band, the outline overlay and the dividers sit
        // over the panes and own their clicks.
        guard let hit = root.hitTest(frame.convert(event.locationInWindow, from: nil)),
              let group = groups.first(where: { $0 !== activeGroup && hit.isDescendant(of: $0.pane) }),
              let tab = group.activeTab else { return }
        activate(tab, focusingEditor: false)
    }

    // MARK: Tab drag over the editor

    /// The drop zone under `windowPoint` for tab `id` dragged over the panes, with the indicator
    /// rect in the pane host; nil where a drop does nothing.
    func dropTarget(forTab id: UUID, atWindowPoint windowPoint: NSPoint)
        -> (group: UUID, zone: TabDropPolicy.Zone, rect: CGRect)? {
        guard let tab = tab(id: id), let source = group(of: tab) else { return nil }
        let point = contentView.convert(windowPoint, from: nil)
        guard let target = groups.first(where: { $0.pane.frame.contains(point) }) else { return nil }
        let frame = target.pane.frame
        guard let zone = TabDropPolicy.zone(at: target.pane.convert(windowPoint, from: nil), in: frame.size, isSourceGroup: target === source,
                                            sourceTabCount: source.tabs.count,
                                            canSplit: canAddGroup) else { return nil }
        return (target.id, zone, TabDropPolicy.overlayRect(for: zone, in: frame))
    }

    /// Show the drop indicator over `rect` (pane host coordinates), or hide it.
    func showDropIndicator(_ rect: CGRect?) {
        contentView.dropOverlay.show(rect)
    }

    /// Commit a drop onto the editor (`dropTarget`'s answer).
    func dropTab(id: UUID, onGroup groupID: UUID, zone: TabDropPolicy.Zone) {
        switch zone {
        case .center:
            moveTab(id: id, toGroup: groupID, at: group(id: groupID)?.tabs.count ?? 0)
        case .leading, .trailing:
            splitTab(id: id, beside: groupID, trailing: zone == .trailing)
        }
    }
}

// MARK: - Compile and PDF

extension EditorContainerViewController {
    /// The file behind the active tab, when it is one Chalk compiles.
    private var activeCompilableURL: URL? {
        guard let url = activeTab?.url, CompileSource(fileExtension: url.pathExtension) != nil else { return nil }
        return url
    }

    var canCompileActive: Bool { activeCompilableURL != nil }
    var canSyncActiveToPDF: Bool { activeCompilableURL.map { CompileSource(fileExtension: $0.pathExtension) == .latex } ?? false }

    /// The root the PDF panel shows: the active file's known root.
    var pdfPanelRoot: URL? {
        activeCompilableURL.flatMap { compiler.knownRoot(for: $0) }
    }

    /// Point the PDF panel at the active tab's root, resolving it first when this session has
    /// not compiled the file yet.
    func refreshPDFPanel() {
        guard let file = activeCompilableURL else {
            pdfPanel.show(root: nil, state: nil)
            return
        }
        if let root = compiler.knownRoot(for: file) {
            pdfPanel.show(root: root, state: compiler.states[root])
            return
        }
        compiler.lookUpRoot(for: file) { [weak self] root in
            guard let self, self.isPDFPanelShowing, self.activeCompilableURL == file else { return }
            self.pdfPanel.show(root: root, state: root.flatMap { self.compiler.states[$0] })
        }
    }

    /// ⌘R: save the active tab, compile its root, and show the PDF.
    func compileActive(showingPDF: Bool = true) {
        guard let file = activeCompilableURL, let tab = activeTab else {
            NSSound.beep()
            return
        }
        guard !CompileController.isSandboxed else {
            presentChalkNotice(title: "Compiling Is Not Available",
                               message: "This build of Chalk runs in the App Sandbox, which cannot start TeX or pandoc.")
            return
        }
        tab.controller.save { [weak self] ok in
            guard let self, ok else { return }
            self.compiler.compile(file) { [weak self] _ in
                guard let self, self.isPDFPanelShowing else { return }
                self.refreshPDFPanel()
            }
            if showingPDF { self.showTrailingPanel(.pdf, animated: true) }
        }
    }

    /// Cmd+S landed on disk: compile when the policy says so (`CompileController.compilesOnSave`).
    fileprivate func compileAfterExplicitSave(of controller: DocumentController) {
        guard let tab = tabs.first(where: { $0.controller === controller }), let url = tab.url,
              compiler.compilesOnSave(url, pdfPanelShowing: isPDFPanelShowing && activeTab === tab),
              !CompileController.isSandboxed else { return }
        compiler.compile(url) { [weak self] _ in
            guard let self, self.isPDFPanelShowing else { return }
            self.refreshPDFPanel()
        }
    }

    /// ⌥⌘J: the PDF spot of the active tab's caret line.
    func syncActiveToPDF() {
        guard let file = activeCompilableURL, CompileSource(fileExtension: file.pathExtension) == .latex,
              let tab = activeTab else {
            NSSound.beep()
            return
        }
        let root = compiler.knownRoot(for: file)
        tab.surface.fetchOutline { [weak self] snapshot in
            guard let self, let snapshot else { return }
            let go = { [weak self] (root: URL?) in
                guard let self, let root else { return NSSound.beep() }
                self.showTrailingPanel(.pdf, animated: true)
                self.compiler.forwardSync(file: file, line: snapshot.cursorLine, root: root) { [weak self] hit in
                    guard let self, let hit else { return NSSound.beep() }
                    self.refreshPDFPanel()
                    self.pdfPanel.reveal(hit)
                }
            }
            if let root { go(root) } else { self.compiler.lookUpRoot(for: file, completion: go) }
        }
    }

    /// Cmd-click in the PDF: open the source at that line.
    private func reverseSync(page: Int, point: CGPoint) {
        guard let pdf = pdfPanel.shownPDF else { return }
        compiler.reverseSync(pdf: pdf, page: page, x: point.x, y: point.y) { [weak self] hit in
            guard let self, let hit else { return NSSound.beep() }
            self.open(url: URL(fileURLWithPath: hit.input))
            self.revealLine(hit.line)
        }
    }

    /// A click on a compile issue: its file (relative to the root's folder) at its line.
    private func jump(to issue: CompileIssue) {
        guard let root = pdfPanelRoot else { return }
        if let file = issue.file {
            let url = URL(fileURLWithPath: file, relativeTo: root.deletingLastPathComponent()).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            open(url: url)
        }
        if let line = issue.line { revealLine(line) }
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

    func documentController(_ controller: DocumentController, didFinishExplicitSave succeeded: Bool) {
        if succeeded { compileAfterExplicitSave(of: controller) }
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

/// A column's resize handle: a horizontal-resize cursor and a drag that reports its x travel.
///
/// A cursor rect alone loses: the views under the handle (the editor's web view, a PDFView)
/// set their own cursor on every mouse move, the web view asynchronously, so the arrows
/// flickered away. While hovered the handle re-asserts its cursor until the mouse leaves.
final class ColumnResizeGrip: FlippedView {
    var onDragBegan: (() -> Void)?
    var onDragged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    /// Draw a thin accent line down the middle while hovered or dragged.
    var showsHoverLine = false {
        didSet {
            if showsHoverLine { wantsLayer = true }
            needsLayout = true
        }
    }
    private var startX: CGFloat = 0
    private var trackingArea: NSTrackingArea?
    private var hovering = false
    private var dragging = false
    private var cursorTimer: Timer?
    private let hoverLine = CALayer()

    #if DEBUG
    var isHoverLineVisibleForTesting: Bool { hoverLine.opacity > 0 }
    #endif

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func layout() {
        super.layout()
        if hoverLine.superlayer == nil, let layer {
            hoverLine.opacity = 0
            layer.addSublayer(hoverLine)
        }
        hoverLine.frame = CGRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height)
    }

    override func viewDidHide() {
        super.viewDidHide()
        setHovering(false)
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }
    override func mouseMoved(with event: NSEvent) { NSCursor.resizeLeftRight.set() }

    private func setHovering(_ on: Bool) {
        hovering = on
        refreshHoverState()
    }

    private func refreshHoverState() {
        let active = (hovering || dragging) && !isHidden
        if active {
            NSCursor.resizeLeftRight.set()
            if cursorTimer == nil {
                let timer = Timer(timeInterval: 0.03, repeats: true) { _ in NSCursor.resizeLeftRight.set() }
                RunLoop.main.add(timer, forMode: .common)
                cursorTimer = timer
            }
        } else {
            cursorTimer?.invalidate()
            cursorTimer = nil
        }
        guard showsHoverLine else { return }
        hoverLine.backgroundColor = NSColor.chalkAccent.withAlphaComponent(dragging ? 0.9 : 0.6).cgColor
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.duration = ChalkMetrics.motionFast
        hoverLine.add(fade, forKey: "fade")
        hoverLine.opacity = active ? 1 : 0
    }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        dragging = true
        refreshHoverState()
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        onDragged?(event.locationInWindow.x - startX)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        hovering = bounds.contains(convert(event.locationInWindow, from: nil))
        refreshHoverState()
        onDragEnded?()
    }
}
