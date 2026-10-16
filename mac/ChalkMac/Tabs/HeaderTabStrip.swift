import AppKit
import ChalkKit

/// A snapshot of one tab for the row.
struct TabItem: Hashable {
    let id: UUID
    let name: String
    let isDirty: Bool
    let isActive: Bool
    /// A "preview" tab (iA Writer): opened but never edited, so a sidebar click
    /// will replace it in place. Only the ACTIVE one is ever replaced, which is
    /// why only the active one carries the slant (TabStripPolicy.isOblique).
    let isPreview: Bool
    /// Immediate parent folder name (no slash) for the label's dim prefix, set
    /// only when another open tab shares this filename
    /// (TabStripPolicy.needsFolderPrefix); nil otherwise.
    let folder: String?

    init(id: UUID, name: String, isDirty: Bool, isActive: Bool,
         isPreview: Bool, folder: String? = nil) {
        self.id = id
        self.name = name
        self.isDirty = isDirty
        self.isActive = isActive
        self.isPreview = isPreview
        self.folder = folder
    }
}

/// A view whose origin is top-left, so the chrome's geometry reads the way the
/// spec and the invariant catalogue state it (y grows downward).
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The tab name row: a quiet mono text row on the editor surface. The active
/// tab is weight plus a short accent underline; background tabs are muted. No
/// band of its own, no chip fill, marker, divider or rounding.
///
/// The underline belongs to the row, not to a tab, so it can slide to the new
/// name on `motionFast` (docs/motion.md "Tab switch"): every model change
/// rebuilds the items.
///
/// Overflow: when more tabs exist than fit, the scroll clips normally, edges
/// fade over 16pt where content is clipped, and a trailing chevron button
/// (hidden when everything fits) opens a menu of every tab. The active tab is
/// always scrolled into view on `update(_:)`.
final class HeaderTabStrip: FlippedView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    /// The "+" glyph (new file).
    var onNew: (() -> Void)?
    /// Drag-reorder drop: tab `id` should move to row position `index`.
    var onMove: ((UUID, Int) -> Void)?

    private let scroll = NSScrollView()
    private let content = FlippedView()
    private let stack = NSStackView()
    private let newTabButton = StripGlyphButton(symbol: "plus", pointSize: ChalkMetrics.newTabGlyphSize,
                                                weight: .light, label: "New File")
    private let overflowButton = StripGlyphButton(symbol: "chevron.down",
                                                  pointSize: TabStripMetrics.overflowGlyph,
                                                  weight: .medium, label: "More Tabs")
    private let fadeMask = CAGradientLayer()
    /// The active name's accent underline, owned by the row so it can slide
    /// between labels instead of being rebuilt with them.
    private let underline = FlippedView()
    /// The id the underline currently sits under, so a rebuild that does not
    /// change the active tab never animates.
    private var underlinedID: UUID?
    /// Whether the underline is mid-slide (NSAnimationContext has no key list
    /// to read; the completion clears it).
    private var underlineSliding = false

    private var items: [TabItem] = []
    /// The newest model this row was asked to show. The close-fade completion
    /// in `update(_:)` must rebuild from this, never from the `items` it
    /// captured, or a second update inside the fade would be reverted (closed
    /// tab resurrected, new tab hidden). Set on every update, parked ones
    /// included, so the replay that ends a drag or a press rebuilds from the
    /// newest model.
    private var latestItems: [TabItem] = []
    private var isOverflowShown = false
    private var overflowWidthZero: NSLayoutConstraint!

    /// Chip drag-reorder in flight: the id being dragged, and any `update(_:)`
    /// snapshots that arrived mid-drag (a rebuild would destroy the dragged
    /// item), parked until the session ends.
    private var draggingID: UUID?
    private var pendingItems: [TabItem]?
    /// The dragged item's position in the row when the lift began, so the end
    /// of the session can tell a reorder from a click with jitter.
    private var dragStartIndex: Int?

    /// The item under a live press. `rebuild` destroys every item, so an
    /// update between mouse-down and mouse-up (a save confirming, a rename)
    /// would take the pressed item and the click it owes with it. Updates park
    /// exactly as they do mid-drag (docs/issues/2026-08-18-tab-needs-two-clicks.md).
    private var pressedTabID: UUID?

    /// Fixed gap between the "+" glyph and the overflow button, reserved even
    /// while the button is collapsed to zero width.
    private static let overflowGap: CGFloat = 8
    private static let newTabSize: CGFloat = ChalkMetrics.newTabButtonSize.width
    /// The fixed tail past the names (gap + "+" glyph + overflow gap), always
    /// reserved, mirroring the constraint chain.
    private static let reservedTail: CGFloat = ChalkMetrics.tabGap + newTabSize + overflowGap

    /// The row's names, in row order.
    private var names: [HeaderTabName] {
        stack.arrangedSubviews.compactMap { $0 as? HeaderTabName }
    }

    /// The active tab's name, nil when no tab is active.
    private var activeName: HeaderTabName? {
        names.first { $0.isActiveItem }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.wantsLayer = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        addSubview(scroll)

        stack.orientation = .horizontal
        stack.spacing = ChalkMetrics.tabGap
        stack.alignment = .height
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        // The underline scrolls WITH the names (it is under one of them), so it
        // lives in the scroll's content beside the stack rather than in the row.
        underline.wantsLayer = true
        underline.layer?.cornerRadius = ChalkMetrics.tabUnderlineHeight / 2
        underline.isHidden = true
        content.addSubview(underline)

        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.white.cgColor,
                            NSColor.white.cgColor, NSColor.clear.cgColor]
        fadeMask.locations = [0, 0, 1, 1]
        scroll.layer?.mask = fadeMask

        newTabButton.onClick = { [weak self] in self?.onNew?() }
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newTabButton)

        overflowButton.setAccessibilityIdentifier("TabOverflow")
        overflowButton.isHidden = true
        overflowButton.translatesAutoresizingMaskIntoConstraints = false
        overflowButton.onClick = { [weak self] in self?.showOverflowMenu() }
        addSubview(overflowButton)

        overflowWidthZero = overflowButton.widthAnchor.constraint(equalToConstant: 0)
        overflowWidthZero.isActive = true

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor, constant: -ChalkMetrics.tabGap),
            newTabButton.widthAnchor.constraint(equalToConstant: ChalkMetrics.newTabButtonSize.width),
            newTabButton.heightAnchor.constraint(equalToConstant: ChalkMetrics.newTabButtonSize.height),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newTabButton.trailingAnchor.constraint(
                equalTo: overflowButton.leadingAnchor, constant: -Self.overflowGap),
            overflowButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            overflowButton.heightAnchor.constraint(equalToConstant: ChalkMetrics.newTabButtonSize.height),
            overflowButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            // The document view's width is the names' own; its origin pins to
            // the clip view, or Auto Layout leaves the width ambiguous and the
            // low-resistance labels collapse to nothing.
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.heightAnchor.constraint(equalTo: scroll.heightAnchor),
        ])
        refreshColors()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: ChalkAppearance.themeDidChange, object: nil)
    }

    /// The names cache their attributed titles: rebuild them in the new theme.
    @objc private func themeDidChange() {
        refreshColors()
        guard draggingID == nil, pressedTabID == nil else { return }
        rebuild(latestItems)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            underline.layer?.backgroundColor = NSColor.chalkTabUnderline.cgColor
        }
    }

    func update(_ items: [TabItem]) {
        // Set BEFORE the parking guard: every replay path rebuilds from
        // `latestItems`, so a burst of parked updates must leave the newest
        // one here, not the last one that got through.
        latestItems = items
        // Updates arriving mid-drag or mid-press are parked and replayed
        // when the gesture ends (a rebuild would destroy the item that owes
        // the action).
        guard draggingID == nil, pressedTabID == nil else {
            pendingItems = items
            return
        }
        // Tab close is the one row change that animates (motion contract): if
        // exactly one existing name is gone and nothing else changed shape, fade
        // it out over motionFast, then rebuild. Opening, switching, renaming,
        // and bulk closes rebuild instantly.
        let newIDs = Set(items.map(\.id))
        let removed = names.filter { !newIDs.contains($0.itemID) }
        if removed.count == 1, stack.arrangedSubviews.count == items.count + 1, window != nil {
            let closing = removed[0]
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = ChalkMetrics.motionFast
                closing.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                // Rebuild from latestItems, not the captured `items` (see the property).
                guard let self else { return }
                self.rebuild(self.latestItems)
            })
        } else {
            rebuild(items)
        }
    }

    #if DEBUG
    /// The tab ids currently rendered, in row order (for the stale close-fade tests).
    var renderedTabIDsForTesting: [UUID] {
        names.map(\.itemID)
    }

    /// The ACTIVE name's live frame in the row's own coordinates, nil when no
    /// tab is active. `chromeLayout(for:)` converts it into root coordinates.
    var activeTabFrameForTesting: CGRect? {
        layoutSubtreeIfNeeded()
        return activeName.map { convert($0.bounds, from: $0) }
    }

    /// The accent underline's live frame in the row's own coordinates, nil
    /// when nothing is active.
    var activeUnderlineFrameForTesting: CGRect? {
        layoutSubtreeIfNeeded()
        return underline.isHidden ? nil : convert(underline.bounds, from: underline)
    }

    var activeLabelFrameForTesting: CGRect? {
        layoutSubtreeIfNeeded()
        guard let item = activeName else { return nil }
        return convert(item.labelFrame, from: item)
    }

    /// One tab's label frame in the row's own coordinates: what the gap
    /// between two names is measured from.
    func labelFrameForTesting(_ id: UUID) -> CGRect? {
        layoutSubtreeIfNeeded()
        guard let item = self.item(for: id) else { return nil }
        return convert(item.labelFrame, from: item)
    }

    /// One tab's whole item frame in the row's own coordinates (the click
    /// target, which is wider than the label by its padding and slot).
    func tabFrameForTesting(_ id: UUID) -> CGRect? {
        layoutSubtreeIfNeeded()
        guard let item = self.item(for: id) else { return nil }
        return convert(item.bounds, from: item)
    }

    /// The "+" glyph as configured, so a test can measure its ink against
    /// the label type it sits beside (Paper: a 13px svg with 8.5px arms).
    var newTabGlyphImageForTesting: NSImage? { newTabButton.image }

    /// Whether the underline is mid-slide, for the motion contract.
    var underlineIsAnimatingForTesting: Bool { underlineSliding }

    /// A tab's live frame in window coordinates, for the middle-click tests.
    func tabFrameInWindowForTesting(_ id: UUID) -> CGRect? {
        guard let item = self.item(for: id) else { return nil }
        return item.convert(item.bounds, to: nil)
    }
    #endif

    /// Middle-click close: the item that owns the point closes. A point on no
    /// tab does nothing. Public so a window-level event monitor can route a
    /// middle button the strip's own `otherMouseUp` did not see.
    func replayMiddleClick(atWindowPoint point: CGPoint) {
        guard let id = tabID(atWindowPoint: point) else { return }
        onClose?(id)
    }

    /// The tab whose name contains `point` (window coordinates), or nil. Item
    /// frames are read live, so the scroll offset and any in-flight overflow
    /// are already accounted for.
    private func tabID(atWindowPoint point: CGPoint) -> UUID? {
        let local = convert(point, from: nil)
        guard bounds.contains(local) else { return nil }
        for item in names where convert(item.bounds, from: item).contains(local) {
            return item.itemID
        }
        return nil
    }

    private func rebuild(_ items: [TabItem]) {
        self.items = items
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            stack.addArrangedSubview(HeaderTabName(item: item, strip: self))
        }
        invalidateIntrinsicContentSize()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Settle any pending Auto Layout pass first: after a burst of
            // update() calls this view's width is decided by its superview's
            // constraints, so forcing only our own subtree can read stale
            // geometry and over- or under-scroll.
            (self.superview ?? self).layoutSubtreeIfNeeded()
            guard let active = self.activeName else { return }
            self.content.scrollToVisible(self.content.convert(active.bounds, from: active))
        }
    }

    private func showOverflowMenu() {
        let menu = NSMenu()
        for item in items {
            let title = TabStripPolicy.menuTitle(name: item.name, folder: item.folder)
            let row = MenuActionItem(title: title) { [weak self] in self?.onSelect?(item.id) }
            row.state = item.isActive ? .on : .off
            menu.addItem(row)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflowButton.bounds.maxY + 4), in: overflowButton)
    }

    override var intrinsicContentSize: NSSize {
        // Recomputed only from update(); invalidating from layout re-enters
        // layout every frame. The fixed tail (gap + "+" glyph + overflow gap)
        // is always reserved, even with the overflow button collapsed.
        let fit = stack.fittingSize.width
        let tail = Self.reservedTail
        return NSSize(width: max(fit + tail, tail), height: ChalkMetrics.tabStripHeight)
    }

    override func layout() {
        super.layout()
        // After a burst of update() calls, the constraint solve that resizes
        // this view can land here before `stack` has settled; forcing the
        // scroll's own layout first makes the content size reflect the items.
        scroll.layoutSubtreeIfNeeded()
        // May update the mask frame/locations and overflow-button visibility;
        // must never call invalidateIntrinsicContentSize() here (see above).
        refreshOverflowState()
        positionUnderline()
    }

    @objc private func scrollBoundsChanged() {
        refreshOverflowState()
    }

    /// The active name just laid itself out, so its LABEL finally has a frame:
    /// place the underline now. A parent's `layout` runs BEFORE its children
    /// are measured, so the row's own pass can only ever see a stale or empty
    /// label, which is why placement is driven from the item.
    fileprivate func activeItemDidLayout() {
        positionUnderline()
    }

    /// Park the underline under the active label: same width, `tabUnderlineGap`
    /// below it. A change of ACTIVE TAB slides (docs/motion.md: "2 slides the
    /// short underline to the new label, 150 ms ease-out"); everything else
    /// (first paint, a resize, a scroll, a rebuild that kept the same active
    /// tab) places it without motion. Frame writes only.
    private func positionUnderline() {
        guard let item = activeName else {
            underline.isHidden = true
            underlinedID = nil
            return
        }
        // An unmeasured label means this pass ran before the item laid itself
        // out; `activeItemDidLayout` will call back the moment it has.
        guard !item.labelFrame.isEmpty else { return }
        let label = content.convert(item.labelFrame, from: item)
        let target = CGRect(x: label.minX,
                            y: label.maxY + ChalkMetrics.tabUnderlineGap,
                            width: label.width,
                            height: ChalkMetrics.tabUnderlineHeight)
        let wasHidden = underline.isHidden
        underline.isHidden = false
        guard abs(target.minX - underline.frame.minX) > 0.5
                || abs(target.width - underline.frame.width) > 0.5
                || abs(target.minY - underline.frame.minY) > 0.5 else {
            underlinedID = item.itemID
            return
        }
        let slides = TabStripPolicy.underlineSlides(
            wasHidden: wasHidden, previousID: underlinedID, newID: item.itemID)
            && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        underlinedID = item.itemID
        guard slides else {
            underline.frame = target
            return
        }
        underlineSliding = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = ChalkMetrics.motionFast
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            underline.animator().frame = target
        }, completionHandler: { [weak self] in
            self?.underlineSliding = false
        })
    }

    /// Re-reads the clipped state and updates the fade mask and overflow-button
    /// visibility. Compares against the width the scroll would have with the
    /// overflow button hidden (self minus the always-reserved tail), not the
    /// scroll's current bounds: those shrink when the button shows, which
    /// would latch "clipped" on. Neither side changes when the button toggles,
    /// so the state cannot oscillate.
    private func refreshOverflowState() {
        updateFade()
        setOverflowVisible(content.frame.width > bounds.width - Self.reservedTail + 1)
    }

    private func setOverflowVisible(_ clipped: Bool) {
        guard clipped != isOverflowShown else { return }
        isOverflowShown = clipped
        overflowButton.isHidden = !clipped
        overflowWidthZero.isActive = !clipped
    }

    private func updateFade() {
        let width = scroll.bounds.width
        guard width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = scroll.bounds
        let fraction = min(16 / width, 0.5)
        let offset = scroll.contentView.bounds.origin.x
        let showLeading = offset > 1
        let showTrailing = offset + width < content.frame.width - 1
        fadeMask.colors = [
            (showLeading ? NSColor.clear : NSColor.white).cgColor,
            NSColor.white.cgColor,
            NSColor.white.cgColor,
            (showTrailing ? NSColor.clear : NSColor.white).cgColor,
        ]
        fadeMask.locations = [0, NSNumber(value: Double(fraction)), NSNumber(value: Double(1 - fraction)), 1]
        CATransaction.commit()
    }

    // MARK: - Press and drag-reorder
    //
    // Press-and-move lifts a name; a right-click opens its context menu. While
    // the session is live, the dimmed source item is walked through the stack
    // as the pointer crosses neighbour midpoints (pure feedback); the model
    // commit is `onMove` at drop, whose resulting update() lands in
    // `pendingItems` and is replayed when the session ends. A lift that ends
    // in the slot it started from is a click.

    /// Press lifecycle, reported by HeaderTabName's mouse overrides.
    func tabPressDidBegin(_ id: UUID) { pressedTabID = id }

    func tabPressDidEnd() {
        guard pressedTabID != nil else { return }
        pressedTabID = nil
        // Deferred a turn on purpose: the item sends its click right after
        // mouse-up returns, and rebuilding synchronously here would destroy
        // the item before its own action fired. A drag lifting out of the
        // press lands here too; its own end-of-session replay owns the
        // rebuild, hence the draggingID check.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingItems != nil,
                  self.draggingID == nil, self.pressedTabID == nil else { return }
            self.pendingItems = nil
            self.update(self.latestItems)
        }
    }

    private func item(for id: UUID?) -> HeaderTabName? {
        guard let id else { return nil }
        return names.first { $0.itemID == id }
    }

    /// The pointer moved past the lift threshold on `id`: a reorder session begins.
    func beginReorder(_ id: UUID) {
        guard draggingID == nil else { return }
        draggingID = id
        dragStartIndex = item(for: id).flatMap { stack.arrangedSubviews.firstIndex(of: $0) }
        item(for: id)?.alphaValue = 0.25
    }

    /// The pointer moved to `x` (this view's coordinates) mid-session.
    func reorderMoved(toX x: CGFloat) {
        guard draggingID != nil else { return }
        walkItem(probeX: content.convert(CGPoint(x: x, y: 0), from: self).x)
        autoscroll(x: x)
    }

    /// The pointer went up. A session that ended in its starting slot is a
    /// click: the item selects. One that moved commits `onMove`.
    func endReorder() {
        guard let id = draggingID else { return }
        let startIndex = dragStartIndex
        let endIndex = item(for: id).flatMap { stack.arrangedSubviews.firstIndex(of: $0) }
        item(for: id)?.alphaValue = 1
        draggingID = nil
        dragStartIndex = nil
        if let endIndex, endIndex != startIndex {
            onMove?(id, endIndex)
        }
        if pendingItems != nil {
            pendingItems = nil
            update(latestItems) // committed drop: rebuild in the new model order
        } else {
            rebuild(items) // cancelled: undo any live reorder feedback
        }
        // After the rebuild: the select round-trips through the host, which
        // pushes a fresh model back into update().
        if endIndex == startIndex { onSelect?(id) }
    }

    /// Move the dimmed source item through the arranged row as the pointer
    /// crosses neighbour midpoints (`TabStripPolicy.reorderStep`); loop so a
    /// fast pass can cross several items in one location update.
    private func walkItem(probeX x: CGFloat) {
        guard let name = item(for: draggingID) else { return }
        while true {
            let arranged = stack.arrangedSubviews
            guard let i = arranged.firstIndex(of: name),
                  let target = TabStripPolicy.reorderStep(
                    index: i, probeX: x, midXs: arranged.map(\.frame.midX))
            else { break }
            stack.removeArrangedSubview(name)
            stack.insertArrangedSubview(name, at: target)
            stack.layoutSubtreeIfNeeded()
        }
    }

    /// Nudge the scroll when the pointer sits near a clipped edge.
    private func autoscroll(x: CGFloat) {
        var offset = scroll.contentView.bounds.origin.x
        if x < scroll.frame.minX + 30 {
            offset -= 12
        } else if x > scroll.frame.maxX - 30 {
            offset += 12
        } else {
            return
        }
        let maxOffset = max(0, content.frame.width - scroll.bounds.width)
        scroll.contentView.scroll(to: NSPoint(x: max(0, min(offset, maxOffset)), y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// A bare glyph with hover brightening: the row's "+" and overflow chevron.
final class StripGlyphButton: FlippedView {
    var onClick: (() -> Void)?
    private(set) var image: NSImage?
    private let imageView = NSImageView()
    private var hovering = false
    private var trackingArea: NSTrackingArea?

    init(symbol: String, pointSize: CGFloat, weight: NSFont.Weight, label: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        imageView.image = image
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        chalkReplaceTrackingArea(&trackingArea)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyStyle() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyStyle() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    private func applyStyle() {
        imageView.contentTintColor = hovering ? .chalkTabIconHover : .chalkTabIcon
    }
}

/// One tab, as typography: [mono label] and, active only, [slot: dirty dot |
/// close ×]. The whole item is the click target; its context menu closes the
/// tab. Structure is decided at init from the immutable item; every model
/// change flows through the row's rebuild. Hover changes colour and alpha only:
/// a size change would re-enter layout.
private final class HeaderTabName: FlippedView {
    var itemID: UUID { item.id }
    var isActiveItem: Bool { item.isActive }
    private var isDirtyItem: Bool { item.isDirty }
    private weak var strip: HeaderTabStrip?
    private let label = TabLabelView()
    /// Rest and hover renderings of the same string, built once so a hover can
    /// swap the label's tone without re-measuring it.
    private var restTitle: NSAttributedString
    private var hoverTitle: NSAttributedString
    private let item: TabItem
    /// The trailing slot's contents: the dot and the ×, cross-faded.
    private let slotDotView = FlippedView()
    private let slotCloseIcon = NSImageView()
    private let slotButton = FlippedView()
    private var hovering = false
    private var slotHovering = false
    private var trackingArea: NSTrackingArea?
    private var slotTrackingArea: NSTrackingArea?
    /// Mouse-down point, for the lift threshold.
    private var pressOrigin: CGPoint?
    private var lifted = false

    /// The label's frame in this item's coordinates: what the row's underline
    /// tracks, and where the hover × is anchored.
    var labelFrame: CGRect { label.frame }

    override func layout() {
        super.layout()
        guard isActiveItem else { return }
        strip?.activeItemDidLayout()
    }

    init(item: TabItem, strip: HeaderTabStrip) {
        self.item = item
        self.strip = strip
        restTitle = Self.title(for: item)
        hoverTitle = Self.title(for: item, hovering: true)
        super.init(frame: .zero)
        wantsLayer = true

        label.attributedText = restTitle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // The hover × for a background tab sits past the item's trailing edge,
        // in the gap after the label, at the offset the active tab's slot
        // occupies. A subview so it travels with the item, never in the layout.
        buildSlot(item: item)

        let padding = ChalkMetrics.tabLabelPadding
        var constraints = [
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: ChalkMetrics.tabMaxWidth),
            heightAnchor.constraint(equalToConstant: ChalkMetrics.tabStripHeight),
        ]
        constraints += [
            slotButton.leadingAnchor.constraint(
                equalTo: label.trailingAnchor, constant: ChalkMetrics.tabInnerGap),
            slotButton.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ]
        if TabStripPolicy.slotIsReserved(isActive: item.isActive, isDirty: item.isDirty) {
            // The active tab's slot is INSIDE the item, so the item grows to hold it.
            constraints.append(
                slotButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding))
        } else {
            // A background tab ends at its label: the slot hangs past the
            // trailing edge into the gap, where it appears on hover only.
            constraints.append(
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding))
        }
        NSLayoutConstraint.activate(constraints)

        setAccessibilityRole(.button)
        setAccessibilityLabel(item.name)
        setAccessibilityIdentifier("Tab-\(item.name)")
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Mono label: a dim "folder/" prefix only where another open tab shares
    /// the filename, then the name. Active is medium weight; the one tab a
    /// browse click will replace slants (TabStripPolicy.isOblique).
    private static func title(for item: TabItem, hovering: Bool = false) -> NSAttributedString {
        let font = NSFont.chalkMono(
            size: ChalkMetrics.tabFontSize,
            weight: item.isActive ? .medium : .regular,
            oblique: TabStripPolicy.isOblique(isActive: item.isActive, isPreview: item.isPreview))
        let pathColor: NSColor = item.isActive ? .chalkTabPathActive : .chalkTabPathInactive
        let nameColor: NSColor = item.isActive || hovering
            ? .chalkTabLabelActive : .chalkTabLabelInactive
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let title = NSMutableAttributedString()
        if let folder = item.folder {
            title.append(NSAttributedString(
                string: folder + "/",
                attributes: [.font: font, .foregroundColor: pathColor,
                             .paragraphStyle: paragraph]))
        }
        title.append(NSAttributedString(
            string: item.name,
            attributes: [.font: font, .foregroundColor: nameColor,
                         .paragraphStyle: paragraph]))
        return title
    }

    /// One × for every chip: the row is rebuilt on each model change.
    private static let closeGlyph = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
        .withSymbolConfiguration(.init(pointSize: TabStripMetrics.closeGlyph, weight: .semibold))

    /// The slot: dot OR × per TabStripPolicy.slotContent, cross-faded on slot
    /// hover for dirty tabs (that swap is how an unsaved tab is closed).
    private func buildSlot(item: TabItem) {
        slotDotView.wantsLayer = true
        slotDotView.layer?.cornerRadius = ChalkMetrics.dirtyDotSize / 2
        slotDotView.translatesAutoresizingMaskIntoConstraints = false

        slotCloseIcon.image = Self.closeGlyph
        slotCloseIcon.imageScaling = .scaleNone
        slotCloseIcon.translatesAutoresizingMaskIntoConstraints = false

        slotButton.setAccessibilityRole(.button)
        slotButton.setAccessibilityLabel("Close Tab")
        addSubview(slotButton)
        slotButton.addSubview(slotDotView)
        slotButton.addSubview(slotCloseIcon)
        slotButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            slotButton.widthAnchor.constraint(equalToConstant: ChalkMetrics.tabSlotWidth),
            slotButton.heightAnchor.constraint(equalToConstant: 22),
            slotDotView.centerXAnchor.constraint(equalTo: slotButton.centerXAnchor),
            slotDotView.centerYAnchor.constraint(equalTo: slotButton.centerYAnchor),
            slotDotView.widthAnchor.constraint(equalToConstant: ChalkMetrics.dirtyDotSize),
            slotDotView.heightAnchor.constraint(equalToConstant: ChalkMetrics.dirtyDotSize),
            slotCloseIcon.centerXAnchor.constraint(equalTo: slotButton.centerXAnchor),
            slotCloseIcon.centerYAnchor.constraint(equalTo: slotButton.centerYAnchor),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        chalkReplaceTrackingArea(&trackingArea, userInfo: ["slot": false])
        chalkReplaceTrackingArea(&slotTrackingArea, rect: slotButton.frame, userInfo: ["slot": true])
    }

    override func mouseEntered(with event: NSEvent) {
        if (event.trackingArea?.userInfo?["slot"] as? Bool) == true {
            guard !slotHovering else { return }
            slotHovering = true
        } else {
            guard !hovering else { return }
            hovering = true
        }
        crossFadeStyle()
    }

    override func mouseExited(with event: NSEvent) {
        if (event.trackingArea?.userInfo?["slot"] as? Bool) == true {
            guard slotHovering else { return }
            slotHovering = false
        } else {
            guard hovering else { return }
            hovering = false
        }
        crossFadeStyle()
    }

    /// Claim the parked slot's rectangle too, but only while the pointer is
    /// already on this tab: otherwise the row would permanently own the gap
    /// between names, which is the window-drag surface.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if bounds.contains(local) { return self }
        guard hovering || slotHovering,
              !TabStripPolicy.slotIsReserved(isActive: isActiveItem, isDirty: isDirtyItem) else { return nil }
        return slotButton.frame.contains(local) ? self : nil
    }

    // MARK: Mouse: click, slot click, lift-to-reorder, middle click, context menu

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        pressOrigin = local
        lifted = false
        alphaValue = 0.7
        strip?.tabPressDidBegin(itemID)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin, let strip else { return }
        let local = convert(event.locationInWindow, from: nil)
        if !lifted, abs(local.x - origin.x) > 4 {
            lifted = true
            alphaValue = 1
            strip.beginReorder(itemID)
        }
        if lifted {
            strip.reorderMoved(toX: strip.convert(event.locationInWindow, from: nil).x)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        alphaValue = 1
        pressOrigin = nil
        guard let strip else { return }
        if lifted {
            lifted = false
            strip.tabPressDidEnd()
            strip.endReorder() // a lift that never moved is a click
            return
        }
        let slotVisible = slotButton.alphaValue > 0 && !slotButton.isHidden
        let onSlot = slotVisible && slotButton.frame.contains(local)
        strip.tabPressDidEnd()
        guard bounds.contains(local) || onSlot else { return }
        if onSlot, slotHovering || !isDirtyItem || isActiveItem {
            // The × (or the dot's hover swap, which is how an unsaved tab closes).
            if TabStripPolicy.slotContent(isDirty: isDirtyItem) == .close || slotHovering {
                strip.onClose?(itemID)
                return
            }
        }
        strip.onSelect?(itemID)
    }

    /// Middle button: close, never a selection (browser convention).
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        strip?.replayMiddleClick(atWindowPoint: event.locationInWindow)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let close = MenuActionItem(title: "Close Tab") { [weak self] in
            guard let self else { return }
            self.strip?.onClose?(self.itemID)
        }
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        menu.addItem(close)
        return menu
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restTitle = Self.title(for: item)
        hoverTitle = Self.title(for: item, hovering: true)
        applyStyle()
    }

    /// Label tone and slot alphas for the current state. Colour/alpha only,
    /// never a size change.
    private func applyStyle() {
        label.attributedText = hovering ? hoverTitle : restTitle
        effectiveAppearance.performAsCurrentDrawingAppearance {
            slotDotView.layer?.backgroundColor = (isActiveItem
                ? NSColor.chalkTabDirtyDotActive : NSColor.chalkTabDirtyDotInactive).cgColor
        }
        switch TabStripPolicy.slotContent(isDirty: isDirtyItem) {
        case .dot:
            slotDotView.alphaValue = slotHovering ? 0 : 1
            slotCloseIcon.alphaValue = slotHovering ? 1 : 0
        case .close:
            // The × rests visible only on the active tab; a background tab's
            // appears on hover.
            slotDotView.alphaValue = 0
            slotCloseIcon.alphaValue = isActiveItem || hovering ? 1 : 0
        }
        // A background tab's whole slot lives in the gap and appears on hover.
        if !TabStripPolicy.slotIsReserved(isActive: isActiveItem, isDirty: isDirtyItem) {
            slotButton.alphaValue = hovering ? 1 : 0
        }
        slotCloseIcon.contentTintColor = slotHovering
            ? .chalkTabLabelActive
            : (isActiveItem ? .chalkTabIcon : .chalkTabIconDim)
    }

    /// Tone and alpha changes ride `motionTab`.
    private func crossFadeStyle() {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            applyStyle()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ChalkMetrics.motionTab
            context.allowsImplicitAnimation = true
            applyStyle()
        }
    }
}

/// A one-line label with exact text metrics: its frame is the string's own
/// width, with no cell padding, so the row's gaps and the underline measure
/// the type itself. Truncates with an ellipsis when squeezed.
final class TabLabelView: FlippedView {
    var attributedText = NSAttributedString() {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        let size = attributedText.size()
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        attributedText.draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
