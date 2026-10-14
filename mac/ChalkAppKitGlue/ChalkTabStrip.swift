import AppKit

/// AppKit-native tab strip for the Catalyst titlebar.
///
/// Why AppKit: Catalyst renders `UIBarButtonItem(customView:)` toolbar items
/// but dispatches their clicks into the main UIKit window at item-local
/// coordinates, where they die. Interactive titlebar content must be AppKit.
///
/// Mirrors HeaderTabStrip in MAC points (the titlebar is not subject to the
/// 0.77× Catalyst scale). The underline belongs to the row, not to a name, so
/// it can slide between names (docs/motion.md, Tab switch).
///
/// State arrives as `update` posts and clicks leave as `action` posts; the
/// vocabulary (names, keys, metrics, colours) is ChalkKit's
/// `TabStripBridge.swift`, compiled into this bundle. Every message carries
/// the NSWindow's `windowNumber`; the strip accepts only messages naming its
/// own window. Key status plays no part in routing.

/// The theme's tab-row colours (ChalkKit `ThemePalette`) as dynamic NSColors;
/// `ChalkPalette` wraps the same pairs in UIColor. Internal: ChalkTitlebarBand
/// uses it.
enum StripColor {
    /// The app's theme, from `windowAppearance`. NSAppearance carries only
    /// light/dark, so the providers read this; whoever changes it must make
    /// the views repaint (`ChalkAppKitGlue.applyTheme`).
    static var theme = ChalkTheme.ink

    static func dynamic(_ pick: @escaping (ThemePalette) -> HexPair) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let (red, green, blue) = pick(theme.palette).components(dark: isDark)
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
    }

    /// The editor's tone; the titlebar cover paints it.
    static let paperFill = dynamic(\.editorBackground)
    static let underline = dynamic(\.accent)
    static let labelActive = dynamic(\.tabLabelActive)
    static let labelInactive = dynamic(\.tabLabelInactive)
    static let pathActive = dynamic(\.tabPathActive)
    static let pathInactive = dynamic(\.tabPathInactive)
    static let dotActive = dynamic(\.tabDotActive)
    static let dotInactive = dynamic(\.tabDotInactive)
    static let icon = dynamic(\.tabIcon)
    static let iconDim = dynamic(\.tabIconDim)
    static let iconHover = dynamic(\.tabIconHover)
}

/// IBM Plex Mono (registered process-wide by the app) with a system-mono
/// fallback; the AppKit half of UIFont.chalkMono.
private func stripFont(weight: NSFont.Weight) -> NSFont {
    let name = weight == .medium ? "IBMPlexMono-Medium" : "IBMPlexMono"
    return NSFont(name: name, size: TabStripMetrics.fontSize)
        ?? .monospacedSystemFont(ofSize: TabStripMetrics.fontSize, weight: weight)
}

/// The preview tab's slant, as a text attribute rather than a font.
///
/// No italic face is bundled. A font-descriptor matrix comes back under
/// Catalyst at `slant × size` points, an invisible smear
/// (docs/issues/2026-08-18-mac-tabs-vanish-when-the-library-is-open.md).
/// `.obliqueness` shears at draw time and keeps the upright advances the
/// strip measures from. `UIFont.chalkMono(oblique:)` uses a matrix, which
/// UIKit honours; both share `TabStripMetrics.obliqueSlant`.
private func obliqueAttributes(_ oblique: Bool) -> [NSAttributedString.Key: Any] {
    oblique ? [.obliqueness: TabStripMetrics.obliqueSlant] : [:]
}

/// One tab's snapshot, decoded from the update notification's userInfo.
struct StripTab {
    let id: String
    let name: String
    let isDirty: Bool
    let isActive: Bool
    let isPreview: Bool
    /// Immediate parent folder name for the label's dim prefix; the sender
    /// omits the key for drafts/root files, so missing decodes as nil.
    let folder: String?

    init?(_ dict: [String: Any]) {
        guard let id = dict[TabStripBridge.idKey] as? String,
              let name = dict[TabStripBridge.nameKey] as? String
        else { return nil }
        self.id = id
        self.name = name
        isDirty = dict[TabStripBridge.dirtyKey] as? Bool ?? false
        isActive = dict[TabStripBridge.activeKey] as? Bool ?? false
        isPreview = dict[TabStripBridge.previewKey] as? Bool ?? false
        folder = dict[TabStripBridge.folderKey] as? String
    }
}

/// A stack view that does not swallow the window drag: it spans the strip,
/// so the gaps between and after the chips land here, not on the strip.
final class DragThroughStackView: NSStackView {
    /// Chips keep their own `mouseDown`; only the gaps land here.
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// A view that never takes a click: the underline is decoration, and the
/// pixels under it belong to the name and to the window's drag.
private final class PaintOnlyView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The strip: chip row + "+" + overflow chevron, laid into the titlebar by
/// `layoutInTitlebar`. Past the width it is given the chips compress (labels
/// truncate, down to `TabStripFit`'s floor) and the chevron menu lists every
/// tab that no longer fits.
final class ChalkTabStripView: NSView {
    /// The empty strip is the window's to drag. This view covers nearly the
    /// whole titlebar and a plain NSView blocks the drag. `performDrag` is
    /// the one that works: `mouseDownCanMoveWindow` and a nil `hitTest` do
    /// not move the window from a titlebar-hosted view.
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    /// The scene window this strip was attached to. Identity goes through
    /// this, never `self.window`: in full screen AppKit rehosts the toolbar
    /// into an NSToolbarFullScreenWindow that reports isKeyWindow even for
    /// background scenes.
    weak var attachedWindow: NSWindow?

    /// Invariant: render only state addressed to this window's number, never
    /// untagged or foreign posts. A rejected update leaves the last own state
    /// on screen; a strip that never had own state solicits a re-push instead.
    private func shouldAccept(_ note: Notification) -> Bool {
        WindowRouting.stripShouldAccept(
            messageWindowNumber: note.userInfo?[TabStripBridge.windowNumberKey] as? Int,
            stripWindowNumber: attachedWindow?.windowNumber)
    }

    /// The titlebar background (owned by ChalkToolbarController) needs the
    /// chips' baseline after every toolbar re-layout.
    var onLayoutChanged: (() -> Void)?

    private let stack = DragThroughStackView()
    /// Owned by the row so it slides between names instead of being rebuilt.
    private let underline = PaintOnlyView()
    /// The tab the underline currently sits under, so a rebuild that did not
    /// change the active tab places it without motion.
    private var underlinedID: String?
    private let newTabButton = HoverChipButton(
        symbol: "plus", pointSize: TabStripMetrics.newTabGlyph, weight: .light,
        size: TabStripMetrics.newTabSize, accessibilityLabel: "New File")
    private let overflowButton = HoverChipButton(
        symbol: "chevron.down", pointSize: TabStripMetrics.overflowGlyph, weight: .medium,
        size: NSSize(width: 18, height: 18), accessibilityLabel: "More Tabs")
    private var tabs: [StripTab] = []
    /// True once this strip has rendered its own state. Keeps the reject-time
    /// solicit finite, and doubles as the glue's pairing ACK.
    private(set) var hasEverAppliedOwnState = false
    private var keyObserver: NSObjectProtocol?
    private var updateObserver: NSObjectProtocol?
    /// Divider X in window coords (mac pt); 0 = sidebar hidden.
    private var dividerX: CGFloat = 0
    /// The outline panel's width from the trailing edge (mac pt); 0 = hidden.
    /// The chips stop at the panel the way they start at the divider.
    private var outlineWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = TabStripMetrics.gap
        // Every name is the row's full height, so the whole row is its tab's
        // click target and the labels sit on one centred line.
        stack.alignment = .centerY
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        underline.wantsLayer = true
        underline.layer?.cornerRadius = TabStripMetrics.underlineHeight / 2
        underline.isHidden = true
        addSubview(underline)

        newTabButton.onClick = { [weak self] in self?.post(action: .new) }
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newTabButton)

        overflowButton.onClick = { [weak self] in self?.showOverflowMenu() }
        overflowButton.isHidden = true
        overflowButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overflowButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            newTabButton.leadingAnchor.constraint(
                equalTo: stack.trailingAnchor, constant: TabStripMetrics.gap),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            overflowButton.leadingAnchor.constraint(
                equalTo: newTabButton.trailingAnchor, constant: TabStripMetrics.gap),
            overflowButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            overflowButton.centerYAnchor.constraint(equalTo: newTabButton.centerYAnchor),
            heightAnchor.constraint(equalToConstant: TabStripMetrics.stripHeight),
        ])

        updateObserver = NotificationCenter.default.addObserver(
            forName: TabStripBridge.update, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let accepted = self.shouldAccept(note)
            guard accepted else {
                // Another window pushed while this one is still empty
                // (multi-window restore): ask our bound scene for a re-push.
                // Only-while-empty keeps the chain finite.
                if WindowRouting.stripShouldSolicitOwnState(
                    didAccept: accepted,
                    hasEverAppliedOwnState: self.hasEverAppliedOwnState) {
                    self.postNeedsState()
                }
                return
            }
            guard let raw = note.userInfo?[TabStripBridge.tabsKey] as? [[String: Any]] else { return }
            self.apply(raw.compactMap(StripTab.init))
        }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, (note.object as? NSWindow) === self.attachedWindow else { return }
            self.postNeedsState()
        }
    }

    /// Pushed by ChalkToolbarController. A sidebar slide carries its duration
    /// and curve; the strip rides that clock and never picks its own
    /// (docs/motion.md). A post without them applies instantly.
    func setDividerGeometry(
        dividerX: CGFloat, outlineWidth: CGFloat,
        slideDuration: TimeInterval?, slideCurve: TabStripBridge.SlideCurve?
    ) {
        self.dividerX = dividerX
        self.outlineWidth = outlineWidth
        layoutInTitlebar(slideDuration: slideDuration, slideCurve: slideCurve)
    }

    /// Called once the active name has laid out: a parent's `layout()` runs
    /// before its children are measured, so the row's own pass can see an
    /// empty label frame.
    fileprivate func activeItemDidLayout() {
        positionUnderline()
    }

    /// Park the underline `underlineGap` below the active name (y-up). Only a
    /// change of active tab slides, and never under Reduce Motion; everything
    /// else places it without motion.
    /// Frame writes only, so this can never re-enter layout.
    private func positionUnderline() {
        guard let item = stack.arrangedSubviews
            .compactMap({ $0 as? TabNameView })
            .first(where: { $0.isActiveTab }) else {
            underline.isHidden = true
            underlinedID = nil
            return
        }
        // Unmeasured: `activeItemDidLayout` will call back.
        guard !item.labelFrame.isEmpty else { return }
        let label = convert(item.labelFrame, from: item)
        let target = NSRect(x: label.minX,
                            y: label.minY - TabStripMetrics.underlineGap
                                - TabStripMetrics.underlineHeight,
                            width: label.width,
                            height: TabStripMetrics.underlineHeight)
        let wasHidden = underline.isHidden
        underline.isHidden = false
        underline.layer?.backgroundColor = StripColor.underline.cgColor
        guard target != underline.frame else {
            underlinedID = item.tabID
            return
        }
        let slides = TabStripPolicy.underlineSlides(
            wasHidden: wasHidden, previousID: underlinedID, newID: item.tabID)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        underlinedID = item.tabID
        guard slides else {
            underline.frame = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ChromeMotion.fast
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            underline.animator().frame = target
        }
    }

    /// Ask the scene bound to this window for a re-push. Self-heal only: an
    /// unbound scene ignores it, since binding comes from the glue's `bind`.
    private func postNeedsState() {
        guard let number = attachedWindow?.windowNumber else { return }
        NotificationCenter.default.post(
            name: TabStripBridge.needsState, object: nil,
            userInfo: [TabStripBridge.windowNumberKey: number])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        [keyObserver, updateObserver].compactMap { $0 }
            .forEach(NotificationCenter.default.removeObserver)
    }

    /// Request fresh state whenever the strip lands in a window (attach and
    /// each full-screen rehost). The key observer misses the first attach: it
    /// is added during the didBecomeKey dispatch. Async so the transition
    /// settles before the answer arrives.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.postNeedsState()
        }
    }


    /// Place this strip inside the titlebar: chips start at the divider plus
    /// `dividerGap`, or past the traffic lights when the Library is hidden.
    ///
    /// A titlebar subview placed by frame, not a toolbar item: the toolbar
    /// centres its items even with `isNavigational`, so an item's chips
    /// cannot reach the divider.
    func layoutInTitlebar(slideDuration: TimeInterval? = nil,
                          slideCurve: TabStripBridge.SlideCurve? = nil) {
        guard let titlebar = superview else { return }
        let leading = max(trafficLightClearance,
                          dividerX > 0 ? dividerX + TabStripMetrics.dividerGap : 0)
        let width = max(120, titlebar.bounds.width - leading - TabStripMetrics.trailingMargin - outlineWidth)
        let target = NSRect(
            x: leading,
            y: max(0, (titlebar.bounds.height - TabStripMetrics.stripHeight) / 2),
            width: width,
            height: TabStripMetrics.stripHeight)
        guard target != frame else { return }
        // A sidebar slide is one large jump tagged with its clock: animate
        // with it so the chips move with the column. Live divider drags are
        // untagged small deltas: apply instantly or the strip lags.
        if let slideDuration, abs(target.origin.x - frame.origin.x) > 40 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = slideDuration
                ctx.timingFunction = CAMediaTimingFunction(
                    name: slideCurve == .easeInOut ? .easeInEaseOut : .easeOut)
                ctx.allowsImplicitAnimation = true
                animator().frame = target
            }
        } else {
            frame = target
        }
        onLayoutChanged?()
    }

    /// Where the chips may start when the Library is hidden: just past the
    /// traffic lights, read off the live buttons rather than hardcoded, so a
    /// system that moves them moves the chips too.
    private var trafficLightClearance: CGFloat {
        guard let zoom = attachedWindow?.standardWindowButton(.zoomButton),
              let container = zoom.superview, !zoom.isHidden
        else { return TabStripMetrics.fallbackLeading }
        let inTitlebar = (superview ?? container).convert(zoom.frame, from: container)
        return inTitlebar.maxX + TabStripMetrics.trafficLightGap
    }

    /// Every action names the window it was clicked in, so the scene bound
    /// to that window handles it.
    func post(action: TabStripBridge.Action, id: String? = nil, index: Int? = nil) {
        var info: [String: Any] = [TabStripBridge.actionKey: action.rawValue]
        if let id { info[TabStripBridge.idKey] = id }
        if let index { info[TabStripBridge.indexKey] = index }
        if let number = attachedWindow?.windowNumber {
            info[TabStripBridge.windowNumberKey] = number
        }
        NotificationCenter.default.post(
            name: TabStripBridge.action, object: nil, userInfo: info)
    }

    /// Chip drag-reorder in progress: `apply` would rebuild every chip and
    /// destroy the one under the cursor, so updates arriving mid-drag are
    /// parked here and replayed on drop.
    private var dragActive = false
    private var pendingTabs: [StripTab]?

    fileprivate func chipDragDidBegin() {
        dragActive = true
    }

    /// Runs inside the dragged item's own mouseDown and may rebuild the chips
    /// (a parked update), so the caller reads its index before calling this.
    fileprivate func chipDragDidEnd() {
        dragActive = false
        if let pending = pendingTabs {
            pendingTabs = nil
            apply(pending)
        }
    }

    /// Reorder `chip` in the arranged row (drag feedback; the model commit is
    /// the `move` action posted on drop). Instant, not animated: the dragged
    /// chip is held under the cursor by a layer transform, and an implicit
    /// frame animation would visibly fight it.
    fileprivate func moveChip(_ chip: NSView, to index: Int) {
        stack.removeArrangedSubview(chip)
        stack.insertArrangedSubview(chip, at: index)
        stack.layoutSubtreeIfNeeded()
    }

    private func apply(_ tabs: [StripTab]) {
        hasEverAppliedOwnState = true
        if dragActive {
            pendingTabs = tabs
            return
        }
        self.tabs = tabs
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tab in tabs {
            stack.addArrangedSubview(TabNameView(tab: tab))
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func showOverflowMenu() {
        let menu = NSMenu()
        for tab in tabs {
            let title = TabStripPolicy.menuTitle(name: tab.name, folder: tab.folder)
            let item = NSMenuItem(
                title: title, action: #selector(overflowPick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tab.id
            item.state = tab.isActive ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: overflowButton.frame.minX, y: overflowButton.frame.minY - 4),
            in: self)
    }

    @objc private func overflowPick(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        post(action: .select, id: id)
    }

    override var intrinsicContentSize: NSSize {
        let chips = stack.fittingSize.width
        let tail = TabStripMetrics.gap + TabStripMetrics.newTabSize.width
        return NSSize(width: chips + tail, height: TabStripMetrics.stripHeight)
    }

    /// Hand the row's width out to the chips, and decide the chevron. The
    /// arithmetic is `TabStripFit`'s: constraint priorities collapsed inactive
    /// labels to nothing
    /// (docs/issues/2026-08-18-mac-tabs-vanish-when-the-library-is-open.md).
    private func applyFitPlan() {
        let chips = stack.arrangedSubviews.compactMap { $0 as? TabNameView }
        guard !chips.isEmpty else {
            if !overflowButton.isHidden { overflowButton.isHidden = true }
            return
        }
        let naturals = chips.map(\.naturalWidth)
        let active = chips.firstIndex { $0.isActiveTab }
        // The chevron's own width is not free. Plan once without it; if the
        // answer needs a chevron, re-plan with the room it takes. Two fixed
        // passes, so the reservation can never oscillate with the decision.
        let tail = TabStripMetrics.gap + TabStripMetrics.newTabSize.width
        let chevron = TabStripMetrics.gap + overflowButton.intrinsicContentSize.width
        var plan = TabStripFit.plan(
            naturalWidths: naturals, activeIndex: active,
            available: bounds.width - tail, spacing: TabStripMetrics.gap)
        if plan.showsOverflow {
            plan = TabStripFit.plan(
                naturalWidths: naturals, activeIndex: active,
                available: bounds.width - tail - chevron, spacing: TabStripMetrics.gap)
        }
        for (index, chip) in chips.enumerated() {
            chip.setPlannedWidth(plan.widths[index])
            let hidden = !plan.isVisible(index)
            if chip.isHidden != hidden { chip.isHidden = hidden }
        }
        if overflowButton.isHidden == plan.showsOverflow {
            overflowButton.isHidden = !plan.showsOverflow
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Dynamic NSColors resolve at read time, and a CGColor does not
        // re-resolve on its own.
        underline.layer?.backgroundColor = StripColor.underline.cgColor
    }

    override func layout() {
        super.layout()
        applyFitPlan()
        positionUnderline()
        // Layout can move a chip out from under a still pointer with no exit
        // event, so re-derive hover from the real pointer position.
        let views = stack.arrangedSubviews + [newTabButton, overflowButton]
        for view in views { (view as? HoverRefreshable)?.refreshHoverFromMousePosition() }
        // The titlebar background paints down to the chips' baseline.
        onLayoutChanged?()
    }
}

/// A view whose hover styling must be re-derived from the actual pointer
/// position after layout moves it (see ChalkTabStripView.layout()).
private protocol HoverRefreshable {
    func refreshHoverFromMousePosition()
}

/// One tab: folder?/name plus the trailing slot (dirty dot or close ×).
/// Click selects, drag reorders, the context menu and middle-click close.
/// Structure is fixed at init (the row rebuilds on every model change); hover
/// changes colour and alpha only.
private final class TabNameView: NSView, HoverRefreshable {
    private let tab: StripTab
    var isActiveTab: Bool { tab.isActive }
    var tabID: String { tab.id }
    private let label = NSTextField(labelWithString: "")
    /// Width with the full "folder/name" label, capped at `maxTabWidth`: the
    /// input TabStripFit plans from.
    private(set) var naturalWidth: CGFloat = 0
    /// The same, for the name-only label a squeezed item falls back to.
    private var compactWidth: CGFloat = 0
    /// Padding, gap and slot: everything but the label.
    private var chrome: CGFloat = 0
    private let fullTitle: NSAttributedString
    private let compactTitle: NSAttributedString
    private let hoverFullTitle: NSAttributedString
    private let hoverCompactTitle: NSAttributedString
    private var showingCompactTitle = false
    /// The width the planner assigned, at required priority.
    private var assignedWidth: NSLayoutConstraint!
    private var slot: StripSlotView!
    var labelFrame: CGRect { label.frame }

    /// The row places its underline from HERE (see `activeItemDidLayout`).
    override func layout() {
        super.layout()
        guard tab.isActive else { return }
        strip?.activeItemDidLayout()
    }
    private var hovering = false {
        didSet {
            guard oldValue != hovering else { return }
            applyStyle()
            slot.chipHovering = hovering
            // The parked slot sits outside `bounds`, so the tracking area has
            // to cover it too or the pointer would "leave" on the way to the ×.
            updateTrackingAreas()
        }
    }

    init(tab: StripTab) {
        self.tab = tab
        fullTitle = Self.title(for: tab)
        compactTitle = Self.title(for: tab, includingFolder: false)
        hoverFullTitle = Self.title(for: tab, hovering: true)
        hoverCompactTitle = Self.title(for: tab, includingFolder: false, hovering: true)
        super.init(frame: .zero)

        label.attributedStringValue = fullTitle
        label.lineBreakMode = .byTruncatingTail
        // The item's width is assigned by TabStripFit; the label yields and
        // truncates inside it.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let padding = TabStripMetrics.labelPadding
        slot = StripSlotView(
            content: TabStripPolicy.slotContent(isDirty: tab.isDirty),
            isActiveTab: tab.isActive)
        slot.onClick = { [weak self, tab] in self?.strip?.post(action: .close, id: tab.id) }
        slot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slot)

        let reserved = TabStripPolicy.slotIsReserved(isActive: tab.isActive, isDirty: tab.isDirty)
        var constraints = [
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            slot.leadingAnchor.constraint(
                equalTo: label.trailingAnchor, constant: TabStripMetrics.innerGap),
            slot.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            heightAnchor.constraint(equalToConstant: TabStripMetrics.stripHeight),
        ]
        if reserved {
            // Dot or × at rest: the slot is inside the item, which grows for it.
            constraints.append(
                slot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding))
        } else {
            // Nothing at rest: the slot hangs in the following gap, revealed on
            // hover, so nothing reflows (see `hitTest`).
            constraints.append(
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding))
        }
        NSLayoutConstraint.activate(constraints)

        // Measured from the parts: `fittingSize` honours the label's low
        // compression resistance and reports the squeezed width.
        chrome = padding * 2
            + (reserved ? TabStripMetrics.slotWidth + TabStripMetrics.innerGap : 0)
        naturalWidth = min(chrome + ceil(fullTitle.size().width), TabStripMetrics.maxTabWidth)
        compactWidth = min(chrome + ceil(compactTitle.size().width), TabStripMetrics.maxTabWidth)

        assignedWidth = widthAnchor.constraint(equalToConstant: naturalWidth)
        assignedWidth.isActive = true

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tab.name)
        setAccessibilityIdentifier("Tab-\(tab.name)")

        let closeItem = NSMenuItem(
            title: "Close Tab", action: #selector(closeFromMenu), keyEquivalent: "")
        closeItem.target = self
        let contextMenu = NSMenu()
        contextMenu.addItem(closeItem)
        menu = contextMenu
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Take the assigned width and pick the label that survives it. Guarded
    /// writes: re-setting an unchanged value from `layout()` loops forever.
    /// A squeezed item sheds "folder/" before truncating, so the few visible
    /// characters are the file name's, not the shared folder's.
    func setPlannedWidth(_ width: CGFloat) {
        let wantsCompact = width < naturalWidth - 0.5 && compactWidth < naturalWidth
        if wantsCompact != showingCompactTitle {
            showingCompactTitle = wantsCompact
            applyStyle()
        }
        guard abs(assignedWidth.constant - width) > 0.5 else { return }
        assignedWidth.constant = width
    }

    /// Mono label: a dim "folder/" prefix only where another open tab shares
    /// the filename, then the name. Active is medium weight; the one tab a
    /// browse click will replace slants (TabStripPolicy.isOblique). `hovering`
    /// lifts a background name to the active tone.
    private static func title(
        for tab: StripTab, includingFolder: Bool = true, hovering: Bool = false
    ) -> NSAttributedString {
        let font = stripFont(weight: tab.isActive ? .medium : .regular)
        let slant = obliqueAttributes(
            TabStripPolicy.isOblique(isActive: tab.isActive, isPreview: tab.isPreview))
        let pathColor = tab.isActive ? StripColor.pathActive : StripColor.pathInactive
        let nameColor = tab.isActive || hovering
            ? StripColor.labelActive : StripColor.labelInactive
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let title = NSMutableAttributedString()
        if let folder = tab.folder, includingFolder {
            title.append(NSAttributedString(
                string: folder + "/",
                attributes: [.font: font, .foregroundColor: pathColor,
                             .paragraphStyle: paragraph].merging(slant) { a, _ in a }))
        }
        title.append(NSAttributedString(
            string: tab.name,
            attributes: [.font: font, .foregroundColor: nameColor,
                         .paragraphStyle: paragraph].merging(slant) { a, _ in a }))
        return title
    }

    /// Tone only: the label's own string carries its colour, so a hover swaps
    /// the prebuilt string rather than re-styling (identical font and text, so
    /// the width cannot change and no reflow can follow).
    private func applyStyle() {
        let hover = hovering && !tab.isActive
        label.attributedStringValue = showingCompactTitle
            ? (hover ? hoverCompactTitle : compactTitle)
            : (hover ? hoverFullTitle : fullTitle)
        // A background name's slot lives in the gap and appears with the hover.
        if !TabStripPolicy.slotIsReserved(isActive: tab.isActive, isDirty: tab.isDirty) {
            slot.alphaValue = hovering ? 1 : 0
        }
    }

    /// The rectangle this item answers for: its own bounds, plus the parked
    /// slot's while the pointer is already on the item.
    private var trackedRect: NSRect {
        TabStripPolicy.slotIsReserved(isActive: tab.isActive, isDirty: tab.isDirty)
            ? bounds
            : bounds.union(slot.frame)
    }

    /// Claim the parked slot's rectangle too, but only while the pointer is
    /// already here: otherwise the row would permanently own the gap between
    /// names, which is the window-drag surface.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point) { return hit }
        guard hovering,
              !TabStripPolicy.slotIsReserved(isActive: tab.isActive, isDirty: tab.isDirty)
        else { return nil }
        let local = convert(point, from: superview)
        return slot.frame.contains(local) ? slot : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: trackedRect,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    func refreshHoverFromMousePosition() {
        guard let window else {
            if hovering { hovering = false }
            return
        }
        let inside = trackedRect.contains(
            convert(window.mouseLocationOutsideOfEventStream, from: nil))
        if hovering != inside { hovering = inside }
    }

    /// Select on click like Safari's background-window tabs.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Without this the window server claims the press as an async window
    /// drag, so tracked events carry a frozen locationInWindow and reorder
    /// never engages. Swallowing mouseDown does not prevent it.
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Drag-reorder (Safari-style: press + horizontal pull)

    private var strip: ChalkTabStripView? { superview?.superview as? ChalkTabStripView }

    /// Press → synchronous tracking loop → select or reorder on release.
    ///
    /// `mouseDragged` never fires for titlebar-hosted views (the window-drag
    /// machinery claims the stream), so the loop dequeues events itself. The
    /// main run loop is blocked meanwhile, so no rebuild lands mid-drag.
    override func mouseDown(with event: NSEvent) {
        guard let window, let stack = superview as? NSStackView, let strip else { return }
        let pressX = event.locationInWindow.x
        let grabOffsetX = stack.convert(event.locationInWindow, from: nil).x - frame.minX
        var dragging = false
        var startIndex: Int?

        while true {
            guard let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture, inMode: .eventTracking, dequeue: true)
            else {
                // Window closed mid-drag: looping would busy-spin. End the
                // session like mouse-up, without the action post.
                if dragging {
                    layer?.setAffineTransform(.identity)
                    layer?.zPosition = 0
                    strip.chipDragDidEnd()
                }
                return
            }

            if next.type == .leftMouseUp {
                if dragging {
                    layer?.setAffineTransform(.identity)
                    layer?.zPosition = 0
                    let index = stack.arrangedSubviews.firstIndex(of: self)
                    strip.chipDragDidEnd()
                    // A drag that never left its slot is a jittery click.
                    if let index, index != startIndex {
                        strip.post(action: .move, id: tab.id, index: index)
                    } else {
                        strip.post(action: .select, id: tab.id)
                    }
                } else if bounds.contains(convert(next.locationInWindow, from: nil)) {
                    strip.post(action: .select, id: tab.id)
                }
                return
            }

            if !dragging {
                // 4pt horizontal threshold keeps plain clicks selecting.
                guard abs(next.locationInWindow.x - pressX) > 4 else { continue }
                dragging = true
                startIndex = stack.arrangedSubviews.firstIndex(of: self)
                hovering = false
                wantsLayer = true
                layer?.zPosition = 100
                strip.chipDragDidBegin()
            }
            // Where the item's leading edge should sit (stack coords), clamped
            // to the row. `frame` ignores the layer transform, so it is always
            // the item's laid-out slot.
            let mouseX = stack.convert(next.locationInWindow, from: nil).x
            let desired = max(0, min(mouseX - grabOffsetX, stack.bounds.width - frame.width))
            // Swap slots whenever the item's visual midpoint crosses a
            // neighbor's midpoint (`TabStripPolicy.reorderStep`); loop so a
            // fast drag can cross several items in one event.
            while true {
                let arranged = stack.arrangedSubviews
                guard let i = arranged.firstIndex(of: self),
                      let target = TabStripPolicy.reorderStep(
                        index: i, probeX: desired + frame.width / 2,
                        midXs: arranged.map(\.frame.midX))
                else { break }
                strip.moveChip(self, to: target)
            }
            layer?.setAffineTransform(CGAffineTransform(translationX: desired - frame.minX, y: 0))
        }
    }

    // MARK: Middle-click close

    /// AppKit numbers mouse buttons from 0 (left, right, middle).
    private static let middleButton = 2

    /// Middle-click closes the tab on release inside the item. The press is
    /// swallowed so nothing upstream claims it; StripSlotView leaves
    /// `otherMouse*` unhandled, so presses on the slot land here too.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == Self.middleButton else {
            super.otherMouseDown(with: event)
            return
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == Self.middleButton else {
            super.otherMouseUp(with: event)
            return
        }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        strip?.post(action: .close, id: tab.id)
    }

    @objc private func closeFromMenu() {
        strip?.post(action: .close, id: tab.id)
    }
}

/// Fixed-size glyph button (the "+" and the overflow chevron); the glyph
/// brightens on hover.
private final class HoverChipButton: NSView, HoverRefreshable {
    var onClick: (() -> Void)?
    private let imageView = NSImageView()
    private var hovering = false {
        didSet {
            imageView.contentTintColor = hovering
                ? StripColor.iconHover : StripColor.icon
        }
    }

    init(symbol: String, pointSize: CGFloat, weight: NSFont.Weight,
         size: NSSize, accessibilityLabel: String) {
        super.init(frame: .zero)
        if let image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: accessibilityLabel) {
            imageView.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
        }
        imageView.contentTintColor = StripColor.icon
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    func refreshHoverFromMousePosition() {
        guard let window else {
            if hovering { hovering = false }
            return
        }
        let inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        if hovering != inside { hovering = inside }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Swallow: keep the titlebar from treating the press as a drag grip.
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
}

/// The chip's trailing slot: the unsaved dot or the close ×, never both
/// (TabStripPolicy). A dirty chip's dot cross-fades to × while the pointer is
/// over the slot, which is how an unsaved tab closes. Alpha/colour only.
private final class StripSlotView: NSView {
    var onClick: (() -> Void)?
    /// Fed by the owning chip's hover state (close reveal on clean chips).
    var chipHovering = false { didSet { refresh() } }
    private let content: TabStripPolicy.SlotContent
    private let isActiveTab: Bool
    private let dot = NSView()
    private let icon = NSImageView()
    private var hovering = false { didSet { refresh() } }

    init(content: TabStripPolicy.SlotContent, isActiveTab: Bool) {
        self.content = content
        self.isActiveTab = isActiveTab
        super.init(frame: .zero)
        wantsLayer = true

        dot.wantsLayer = true
        dot.layer?.cornerRadius = TabStripMetrics.dotSize / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        if let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab") {
            icon.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: TabStripMetrics.closeGlyph, weight: .semibold))
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: TabStripMetrics.slotWidth),
            heightAnchor.constraint(equalToConstant: 16),
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: TabStripMetrics.dotSize),
            dot.heightAnchor.constraint(equalToConstant: TabStripMetrics.dotSize),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Close Tab")
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func refresh() {
        switch content {
        case .dot:
            dot.alphaValue = hovering ? 0 : 1
            icon.alphaValue = hovering ? 1 : 0
        case .close:
            dot.alphaValue = 0
            icon.alphaValue = isActiveTab || chipHovering || hovering ? 1 : 0
        }
        icon.contentTintColor = hovering
            ? StripColor.labelActive
            : (isActiveTab ? StripColor.icon : StripColor.iconDim)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        dot.layer?.backgroundColor =
            (isActiveTab ? StripColor.dotActive : StripColor.dotInactive).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
}

/// Per-window toolbar owner: replaces the window's toolbar with one whose
/// single item is the AppKit strip, pinned leading (navigational). Retained by
/// ChalkAppKitGlue's per-window map (NSToolbar.delegate is unretained).
final class ChalkToolbarController: NSObject, NSToolbarDelegate {
    private static let stripItem = NSToolbarItem.Identifier("chalk.tabstrip.appkit")
    let strip = ChalkTabStripView()
    /// Clicks in the band over the Library panel (see ChalkTitlebarBandView).
    let band = ChalkTitlebarBandView()
    /// Paint under the toolbar (ChalkTitlebarBackgroundView).
    let background = ChalkTitlebarBackgroundView()
    /// The titlebar's share of a palette's scrim: the UIKit scrim cannot
    /// reach the titlebar.
    private let paletteScrim = NSView()
    /// The toolbar only holds the titlebar open to the strip's height. Built
    /// once here: AppKit calls the item factory again on every full-screen
    /// transition.
    private lazy var toolbarSpacer: NSView = {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spacer.widthAnchor.constraint(equalToConstant: 1),
            spacer.heightAnchor.constraint(equalToConstant: TabStripMetrics.stripHeight),
        ])
        return spacer
    }()
    private var resizeObserver: NSObjectProtocol?
    private var insetObserver: NSObjectProtocol?
    private var fullScreenObservers: [NSObjectProtocol] = []

    func attach(to window: NSWindow) {
        strip.attachedWindow = window
        band.attachedWindow = window
        strip.onLayoutChanged = { [weak self] in self?.syncBackgroundBaseline() }
        let toolbar = NSToolbar(identifier: "chalk.titlebar.appkit")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden

        // The one reader of divider/outline geometry for all three titlebar
        // views.
        insetObserver = NotificationCenter.default.addObserver(
            forName: TabStripBridge.leadingInset, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, WindowRouting.stripShouldAccept(
                messageWindowNumber: note.userInfo?[TabStripBridge.windowNumberKey] as? Int,
                stripWindowNumber: self.strip.attachedWindow?.windowNumber),
                  let x = note.userInfo?[TabStripBridge.dividerXKey] as? CGFloat else { return }
            let outline = note.userInfo?[TabStripBridge.outlineWidthKey] as? CGFloat ?? 0
            self.band.setDividerX(x)
            self.background.setDividerGeometry(dividerX: x, outlineWidth: outline)
            self.strip.setDividerGeometry(
                dividerX: x, outlineWidth: outline,
                slideDuration: note.userInfo?[TabStripBridge.durationKey] as? TimeInterval,
                slideCurve: (note.userInfo?[TabStripBridge.curveKey] as? String)
                    .flatMap(TabStripBridge.SlideCurve.init(rawValue:)))
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            self.installBand(in: window) // cheap: the fast paths inside no-op
        }
        // Full-screen transitions rebuild the titlebar (the toolbar is
        // rehosted in another window).
        for name in [NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification] {
            fullScreenObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] note in
                guard let self, let window = note.object as? NSWindow else { return }
                self.installBand(in: window)
            })
        }
        installBand(in: window)
    }

    /// Park the band over the titlebar, topmost. Idempotent and re-run because
    /// AppKit rebuilds the titlebar around full-screen transitions and
    /// reorders its subviews; a band under the NSToolbarView gets no clicks.
    func installBand(in window: NSWindow) {
        installBackground(in: window)
        installStrip(in: window)
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview
        else { return }
        // Fast path for resize ticks: re-adding forces a reorder and redisplay
        // on every frame of a live resize.
        if band.superview === titlebar, titlebar.subviews.last === band,
           band.frame == titlebar.bounds {
            return
        }
        band.frame = titlebar.bounds
        band.autoresizingMask = [.width, .height]
        titlebar.addSubview(band, positioned: .above, relativeTo: nil)
    }

    /// The strip sits above the background paint and below the band, so the
    /// Library's slice keeps its clicks. Re-run with its two neighbours.
    private func installStrip(in window: NSWindow) {
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview
        else { return }
        if strip.superview !== titlebar {
            strip.translatesAutoresizingMaskIntoConstraints = true
            titlebar.addSubview(strip, positioned: .above, relativeTo: background)
        }
        strip.layoutInTitlebar()
        // This may be a different titlebar (full-screen rehost): re-assert the
        // scrim and presentation the shell last asked for.
        if stripScrimmed || paletteScrim.superview != nil {
            setScrimmed(stripScrimmed, duration: 0)
        }
        applyStripPresentation()
    }

    /// Toolbar and strip hide together, or a hidden toolbar leaves the chips
    /// floating. Neither this nor `setChipsFaded` writes `isHidden` alone:
    /// both resolve through `StripPresentationPolicy`, so a full-screen exit
    /// cannot make faded chips clickable and an un-fade cannot resurrect a
    /// strip full screen hid.
    private(set) var chromeVisible = true
    func setChromeVisible(_ visible: Bool, in window: NSWindow) {
        chromeVisible = visible
        window.toolbar?.isVisible = visible
        applyStripPresentation()
    }

    /// The chip fade (auto-hide and zen). AppKit hit-tests alpha-0 views, so
    /// a completed fade-out also hides the strip; an un-fade un-hides first.
    /// The flag stops a stale fade-out completion hiding a re-shown strip.
    private(set) var chipsFaded = false
    func setChipsFaded(_ faded: Bool, duration: TimeInterval) {
        chipsFaded = faded
        let target = StripPresentationPolicy.resolve(
            chromeVisible: chromeVisible, chipsFaded: faded)
        if !target.isHidden {
            strip.isHidden = false
            background.isHidden = false
        }
        guard duration > 0 else {
            applyStripPresentation()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            self.strip.animator().alphaValue = target.alpha
            self.background.animator().alphaValue = target.alpha
        }, completionHandler: { [weak self] in
            guard let self, self.chipsFaded == faded else { return }
            self.applyStripPresentation()
        })
    }

    /// Dim the titlebar while a palette is up. An overlay, separate from
    /// `setChipsFaded` (which removes the strip), so the two states compose.
    private(set) var stripScrimmed = false
    func setScrimmed(_ scrimmed: Bool, duration: TimeInterval) {
        stripScrimmed = scrimmed
        guard let titlebar = strip.superview else { return }
        if paletteScrim.superview !== titlebar {
            paletteScrim.wantsLayer = true
            paletteScrim.alphaValue = 0
            titlebar.addSubview(paletteScrim, positioned: .above, relativeTo: strip)
        }
        layOutPaletteScrim(in: titlebar)
        guard duration > 0 else {
            paletteScrim.alphaValue = scrimmed ? 1 : 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            self.paletteScrim.animator().alphaValue = scrimmed ? 1 : 0
        }
    }

    /// The scrim covers the whole titlebar. The traffic lights stay undimmed
    /// because they sit above it: the strip is inserted directly above
    /// `background`, and the scrim directly above the strip.
    private func layOutPaletteScrim(in titlebar: NSView) {
        paletteScrim.frame = titlebar.bounds
        paletteScrim.autoresizingMask = [.width, .height]
        let isDark = (titlebar.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) ?? .aqua) == .darkAqua
        let c = ChromeScrim.components(dark: isDark)
        paletteScrim.layer?.backgroundColor = NSColor(
            srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha).cgColor
    }

    /// Write the resolved presentation to both views; `installStrip`
    /// re-asserts it after AppKit rebuilds the titlebar.
    private func applyStripPresentation() {
        let presentation = StripPresentationPolicy.resolve(
            chromeVisible: chromeVisible, chipsFaded: chipsFaded)
        strip.isHidden = presentation.isHidden
        background.isHidden = presentation.isHidden
        strip.alphaValue = presentation.alpha
        background.alphaValue = presentation.alpha
    }

    /// The background goes under everything in the titlebar, toolbar view
    /// included. Same idempotent re-install as the band, opposite z-order.
    private func installBackground(in window: NSWindow) {
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview
        else { return }
        if background.superview === titlebar, titlebar.subviews.first === background,
           background.frame == titlebar.bounds {
            return
        }
        background.frame = titlebar.bounds
        background.autoresizingMask = [.width, .height]
        titlebar.addSubview(background, positioned: .below, relativeTo: nil)
        syncBackgroundBaseline()
    }

    /// Chips' baseline in titlebar coordinates (y-up). Only meaningful while
    /// the strip and background share a window.
    private func syncBackgroundBaseline() {
        guard strip.window != nil, strip.window === background.window,
              let container = background.superview else { return }
        let stripInTitlebar = container.convert(strip.bounds, from: strip)
        background.setChipBaseline(stripInTitlebar.minY)
    }

    deinit {
        [resizeObserver, insetObserver].compactMap { $0 }
            .forEach(NotificationCenter.default.removeObserver)
        for observer in fullScreenObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.stripItem, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.stripItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = toolbarSpacer
        item.isNavigational = true
        // Liquid Glass (macOS 26+) puts each bordered item on a glass platter,
        // which around the 1pt spacer draws a dark line in the tab row
        // (docs/issues/2026-09-17-macos-27-breaks-the-mac-chrome.md).
        item.isBordered = false
        return item
    }
}
