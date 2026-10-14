import ChalkKit
import UIKit

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

extension WindowRouting {
    /// The one serializer for strip updates. Every push is the full snapshot of
    /// the scene's tabs (id, name, dirty, active, preview), never a diff, so no
    /// push can drop the preview slant or the active highlight. Lives here
    /// rather than in ChalkKit because `TabItem` is an app-target type;
    /// `ChalkTabStrip.StripTab` decodes the same `TabStripBridge` keys.
    static func stripPayload(_ items: [TabItem]) -> [[String: Any]] {
        items.map { item in
            var payload: [String: Any] = [
                TabStripBridge.idKey: item.id.uuidString,
                TabStripBridge.nameKey: item.name,
                TabStripBridge.dirtyKey: item.isDirty,
                TabStripBridge.activeKey: item.isActive,
                TabStripBridge.previewKey: item.isPreview,
            ]
            // Omitted (not "") when absent; StripTab treats missing as nil.
            if let folder = item.folder { payload[TabStripBridge.folderKey] = folder }
            return payload
        }
    }
}

/// The tab name row: a quiet mono text row on the editor surface. The active
/// tab is weight plus a short accent underline; background tabs are muted. No
/// band of its own, no chip fill, marker, divider or rounding.
///
/// The underline belongs to the row, not to a tab, so it can slide to the new
/// name on `motionFast` (docs/motion.md "Tab switch"): every model change
/// rebuilds the items.
///
/// Plain UIScrollView + UIStackView: a UICollectionView in a Catalyst title-bar
/// context aborts window creation.
///
/// Overflow: when more tabs exist than fit, the scroll clips normally, edges
/// fade over 16pt where content is clipped, and a trailing chevron button
/// (hidden when everything fits) opens a menu of every tab. The active tab is
/// always scrolled into view on `update(_:)`.
final class HeaderTabStrip: UIView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    /// The "+" glyph (new file).
    var onNew: (() -> Void)?
    /// Drag-reorder drop: tab `id` should move to row position `index`.
    var onMove: ((UUID, Int) -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let newTabButton = UIButton(type: .system)
    private let overflowButton = UIButton(type: .system)
    private let fadeMask = CAGradientLayer()
    /// The active name's accent underline, owned by the row so it can slide
    /// between labels instead of being rebuilt with them.
    private let underline = UIView()
    /// The id the underline currently sits under, so a rebuild that does not
    /// change the active tab never animates.
    private var underlinedID: UUID?

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

    /// The item under a live press, from its own UIControl tracking. `rebuild`
    /// destroys every item, so an update between touch-down and touch-up (a
    /// save confirming, a rename) would take the pressed item and the
    /// `.touchUpInside` it owes with it. Updates park exactly as they do
    /// mid-drag (docs/issues/2026-08-18-tab-needs-two-clicks.md).
    private var pressedTabID: UUID?

    /// Fixed gap between the "+" glyph and the overflow button, reserved even
    /// while the button is collapsed to zero width.
    private static let overflowGap: CGFloat = ChalkMetrics.s(8)
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = ChalkMetrics.tabGap
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        // The underline scrolls WITH the names (it is under one of them), so it
        // lives in the scroll's content beside the stack rather than in the row.
        underline.backgroundColor = .chalkTabUnderline
        underline.layer.cornerRadius = ChalkMetrics.tabUnderlineHeight / 2
        underline.isUserInteractionEnabled = false
        underline.isHidden = true
        scroll.addSubview(stack)
        scroll.addSubview(underline)

        addInteraction(UIDropInteraction(delegate: self))

        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.colors = [UIColor.clear.cgColor, UIColor.white.cgColor,
                            UIColor.white.cgColor, UIColor.clear.cgColor]
        fadeMask.locations = [0, 0, 1, 1]
        scroll.layer.mask = fadeMask
        scroll.delegate = self

        // "+" — a bare weight-300 glyph, no fill ever (spec .tab-new).
        var newConfig = UIButton.Configuration.plain()
        newConfig.image = UIImage(
            systemName: "plus",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: ChalkMetrics.newTabGlyphSize, weight: .light))
        newConfig.contentInsets = .zero
        newTabButton.configuration = newConfig
        newTabButton.tintColor = .chalkTabIcon
        newTabButton.accessibilityLabel = "New File"
        newTabButton.isPointerInteractionEnabled = true
        newTabButton.configurationUpdateHandler = { btn in
            btn.tintColor = btn.isHighlighted || btn.isHovered
                ? .chalkTabIconHover : .chalkTabIcon
        }
        newTabButton.addAction(UIAction { [weak self] _ in self?.onNew?() }, for: .touchUpInside)
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newTabButton)

        var overflowConfig = UIButton.Configuration.plain()
        overflowConfig.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: ChalkMetrics.s(TabStripMetrics.overflowGlyph), weight: .medium))
        overflowConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        overflowButton.configuration = overflowConfig
        overflowButton.tintColor = .chalkTabIcon
        overflowButton.configurationUpdateHandler = { btn in
            btn.tintColor = btn.isHighlighted || btn.isHovered
                ? .chalkTabIconHover : .chalkTabIcon
        }
        overflowButton.showsMenuAsPrimaryAction = true
        overflowButton.accessibilityIdentifier = "TabOverflow"
        overflowButton.accessibilityLabel = "More Tabs"
        overflowButton.isHidden = true
        overflowButton.translatesAutoresizingMaskIntoConstraints = false
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
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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
            UIView.animate(withDuration: ChalkMetrics.motionFast,
                           animations: { closing.alpha = 0 },
                           // Rebuild from latestItems, not the captured `items`
                           // (see the property).
                           completion: { [weak self] _ in
                               guard let self else { return }
                               self.rebuild(self.latestItems)
                           })
        } else {
            rebuild(items)
        }
    }

    #if DEBUG
    /// The tab ids currently rendered, in row order (for the stale close-fade
    /// tests).
    var renderedTabIDsForTesting: [UUID] {
        names.map(\.itemID)
    }

    /// The ACTIVE name's live frame in the row's own coordinates, nil when no
    /// tab is active. `chromeLayout(for:)` converts it into root coordinates.
    ///
    /// Flushes the row's own pending layout first: `rebuild` settles item
    /// geometry on a later runloop hop, and an item added but not yet laid out
    /// reports its pre-alignment frame. Idempotent and scoped to this subtree.
    var activeTabFrameForTesting: CGRect? {
        layoutIfNeeded()
        return activeName.map { $0.convert($0.bounds, to: self) }
    }

    /// The accent underline's live frame in the row's own coordinates, and the
    /// active LABEL's frame it is supposed to track. Nil when nothing is
    /// active. Reported as a pair because the invariant is a relationship.
    var activeUnderlineFrameForTesting: CGRect? {
        layoutIfNeeded()
        return underline.isHidden ? nil : convert(underline.bounds, from: underline)
    }

    var activeLabelFrameForTesting: CGRect? {
        layoutIfNeeded()
        guard let item = activeName else { return nil }
        return item.convert(item.labelFrame, to: self)
    }

    /// One tab's label frame in the row's own coordinates: what the gap
    /// between two names is measured from.
    func labelFrameForTesting(_ id: UUID) -> CGRect? {
        layoutIfNeeded()
        guard let item = self.item(for: id) else { return nil }
        return item.convert(item.labelFrame, to: self)
    }

    /// One tab's whole item frame in the row's own coordinates (the click
    /// target, which is wider than the label by its padding and slot).
    func tabFrameForTesting(_ id: UUID) -> CGRect? {
        layoutIfNeeded()
        guard let item = self.item(for: id) else { return nil }
        return item.convert(item.bounds, to: self)
    }

    /// The "+" glyph as configured, so a test can measure its ink against
    /// the label type it sits beside (Paper: a 13px svg with 8.5px arms).
    var newTabGlyphImageForTesting: UIImage? {
        newTabButton.configuration?.image
    }

    /// Whether the underline is mid-slide, for the motion contract.
    var underlineIsAnimatingForTesting: Bool {
        !(underline.layer.animationKeys() ?? []).isEmpty
    }

    /// A tab's live frame in window coordinates, for the middle-click replay
    /// tests (which speak the same window points the glue forwards).
    func tabFrameInWindowForTesting(_ id: UUID) -> CGRect? {
        guard let item = self.item(for: id) else { return nil }
        return item.convert(item.bounds, to: nil)
    }
    #endif

    /// Middle-click close, full screen only (the windowed row is the
    /// AppKit one, which handles the button itself). Catalyst never delivers
    /// the middle button to UIKit as a touch, so the glue's NSEvent monitor
    /// forwards the point in window coordinates and this turns it back into
    /// the close it would have been. A point on no tab does nothing.
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
        for item in names where item.convert(item.bounds, to: self).contains(local) {
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

        overflowButton.menu = UIMenu(children: items.map { item in
            let title = TabStripPolicy.menuTitle(name: item.name, folder: item.folder)
            return UIAction(title: title, state: item.isActive ? .on : .off) { [weak self] _ in
                self?.onSelect?(item.id)
            }
        })

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Settle any pending Auto Layout pass first: after a burst of
            // update() calls this view's width is decided by its superview's
            // constraints, so forcing only our own subtree can read stale
            // geometry and over- or under-scroll. Scoped to the superview, not
            // the window, which would relayout the whole hierarchy on every tab
            // change.
            (self.superview ?? self).layoutIfNeeded()
            guard let active = self.activeName else { return }
            self.scroll.scrollRectToVisible(self.scroll.convert(active.bounds, from: active), animated: false)
        }
    }

    override var intrinsicContentSize: CGSize {
        // Recomputed only from update(); invalidating from layoutSubviews
        // re-enters layout every frame.
        //
        // The fixed tail (gap + "+" glyph + overflow gap) is always reserved,
        // even with the overflow button collapsed, mirroring the constraint
        // chain so the scroll's content never reads as clipped at the row's
        // natural size.
        let fit = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        let tail = Self.reservedTail
        return CGSize(width: max(fit + tail, tail), height: ChalkMetrics.tabStripHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // After a burst of update() calls, the constraint solve that resizes
        // this view can land here before `stack` has settled, leaving
        // scroll.contentSize briefly stale. Forcing scroll's own layout first
        // (its subtree only, no re-entry) makes contentSize reflect the current
        // items.
        scroll.layoutIfNeeded()
        // May update the mask frame/locations and overflow-button visibility;
        // must never call invalidateIntrinsicContentSize() here (see above).
        refreshOverflowState()
        positionUnderline()
    }

    /// The active name just laid itself out, so its LABEL finally has a frame:
    /// place the underline now. A parent's `layoutSubviews` runs BEFORE its
    /// children are measured, so the row's own pass can only ever see a stale
    /// or empty label — which is why placement is driven from the item.
    fileprivate func activeItemDidLayout() {
        positionUnderline()
    }

    /// Park the underline under the active label: same width, `tabUnderlineGap`
    /// below it. A change of ACTIVE TAB slides (docs/motion.md: "2 slides the
    /// short underline to the new label, 150 ms ease-out"); everything else —
    /// first paint, a resize, a scroll, a rebuild that kept the same active tab
    /// — places it without motion. Frame writes only, so this can never
    /// re-enter layout.
    private func positionUnderline() {
        guard let item = activeName else {
            underline.isHidden = true
            underlinedID = nil
            return
        }
        // An unmeasured label means this pass ran before the item laid itself
        // out; `activeItemDidLayout` will call back the moment it has. Keeping
        // the underline where it is beats moving it to a transient zero, which
        // is a flicker, not a state.
        guard !item.labelFrame.isEmpty else { return }
        let label = scroll.convert(item.labelFrame, from: item)
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
            && window != nil && !UIAccessibility.isReduceMotionEnabled
        underlinedID = item.itemID
        guard slides else {
            underline.frame = target
            return
        }
        UIView.animate(withDuration: ChalkMetrics.motionFast, delay: 0,
                       options: [.beginFromCurrentState, .curveEaseOut]) {
            self.underline.frame = target
        }
    }

    /// Re-reads the clipped state and updates the fade mask and overflow-button
    /// visibility. Called from layoutSubviews (resizes) and scrollViewDidScroll
    /// (the scroll-to-active settling after this view's bounds stop changing).
    ///
    /// Compares against the width the scroll would have with the overflow
    /// button hidden (self minus the always-reserved tail), not the scroll's
    /// current bounds: those shrink when the button shows, which would latch
    /// "clipped" on. Neither side changes when the button toggles, so the state
    /// cannot oscillate.
    private func refreshOverflowState() {
        updateFade()
        setOverflowVisible(scroll.contentSize.width > bounds.width - Self.reservedTail + 1)
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
        let showLeading = scroll.contentOffset.x > 1
        let showTrailing = scroll.contentOffset.x + width < scroll.contentSize.width - 1
        fadeMask.colors = [
            (showLeading ? UIColor.clear : UIColor.white).cgColor,
            UIColor.white.cgColor,
            UIColor.white.cgColor,
            (showTrailing ? UIColor.clear : UIColor.white).cgColor,
        ]
        fadeMask.locations = [0, NSNumber(value: Double(fraction)), NSNumber(value: Double(1 - fraction)), 1]
        CATransaction.commit()
    }
}

extension HeaderTabStrip: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        refreshOverflowState()
    }
}

// MARK: - Drag-reorder (UIDrag/UIDropInteraction, local-only)
//
// Press-and-move lifts a name; a right-click still opens its context menu
// (the system arbitrates the two interactions). While the session is live, the
// dimmed source item is walked through the stack as the pointer crosses
// neighbor midpoints — pure feedback; the model commit is `onMove` in
// performDrop, whose resulting update() lands in `pendingItems` and is
// replayed when the session ends.
extension HeaderTabStrip: UIDragInteractionDelegate, UIDropInteractionDelegate {
    /// Press lifecycle, reported by HeaderTabName's tracking overrides.
    func tabPressDidBegin(_ id: UUID) { pressedTabID = id }

    func tabPressDidEnd() {
        guard pressedTabID != nil else { return }
        pressedTabID = nil
        // Deferred a turn on purpose: UIControl sends `.touchUpInside` right
        // after `endTracking` returns, and rebuilding synchronously here would
        // destroy the item before its own action fired — the exact lost click
        // this parking exists to prevent. A drag lifting out of the press
        // (cancelTracking) lands here too; its own end-of-session replay owns
        // the rebuild, hence the draggingID check.
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

    func dragInteraction(
        _ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession
    ) -> [UIDragItem] {
        guard let name = interaction.view as? HeaderTabName else { return [] }
        // Empty provider: the id travels in localObject only, so this item is
        // meaningless to any other drop target (e.g. the editor webview).
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = name.itemID
        return [item]
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        sessionIsRestrictedToDraggingApplication session: UIDragSession
    ) -> Bool { true }

    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) {
        guard let id = session.items.first?.localObject as? UUID else { return }
        draggingID = id
        dragStartIndex = item(for: id).flatMap { stack.arrangedSubviews.firstIndex(of: $0) }
        item(for: id)?.alpha = 0.25
    }

    /// A lift that ends in the slot it started from is a click, not a move: for
    /// an indirect pointer (the Catalyst mouse) UIDragInteraction
    /// lifts on press plus a few points with no delay, cancelling the item's
    /// UIControl tracking, so `.touchUpInside` never fires
    /// (docs/issues/2026-08-18-tab-needs-two-clicks.md). The AppKit row applies
    /// the same rule on mouse-up. Checked at the end of the session because
    /// UIDragInteraction owns its gesture and cannot be given a threshold.
    func dragInteraction(
        _ interaction: UIDragInteraction, session: UIDragSession,
        didEndWith operation: UIDropOperation
    ) {
        let id = draggingID
        let startIndex = dragStartIndex
        let endIndex = item(for: id).flatMap { stack.arrangedSubviews.firstIndex(of: $0) }
        item(for: id)?.alpha = 1
        draggingID = nil
        dragStartIndex = nil
        if pendingItems != nil {
            pendingItems = nil
            update(latestItems) // committed drop: rebuild in the new model order
        } else {
            rebuild(items) // cancelled: undo any live reorder feedback
        }
        // After the rebuild: the select round-trips through the host, which
        // pushes a fresh model back into update().
        if let id, endIndex == startIndex { onSelect?(id) }
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        draggingID != nil && session.localDragSession?.items.first?.localObject is UUID
    }

    func dropInteraction(
        _ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        walkItem(for: session)
        autoscroll(for: session)
        return UIDropProposal(operation: .move)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let id = draggingID, let name = item(for: id),
              let index = stack.arrangedSubviews.firstIndex(of: name) else { return }
        onMove?(id, index)
    }

    /// Move the dimmed source item through the arranged row as the pointer
    /// crosses neighbor midpoints (`TabStripPolicy.reorderStep`); loop so a
    /// fast pass can cross several items in one location update.
    private func walkItem(for session: UIDropSession) {
        guard let name = item(for: draggingID) else { return }
        let x = session.location(in: stack).x
        while true {
            let arranged = stack.arrangedSubviews
            guard let i = arranged.firstIndex(of: name),
                  let target = TabStripPolicy.reorderStep(
                    index: i, probeX: x, midXs: arranged.map(\.frame.midX))
            else { break }
            UIView.animate(withDuration: ChalkMetrics.motionFast) {
                self.stack.insertArrangedSubview(name, at: target)
                self.stack.layoutIfNeeded()
            }
        }
    }

    /// Nudge the scroll when the pointer sits near a clipped edge. Advances on
    /// pointer movement only (sessionDidUpdate has no displaylink) — enough to
    /// reach offscreen names in an overflowing row.
    private func autoscroll(for session: UIDropSession) {
        let x = session.location(in: self).x
        var offset = scroll.contentOffset.x
        if x < scroll.frame.minX + 30 {
            offset -= 12
        } else if x > scroll.frame.maxX - 30 {
            offset += 12
        } else {
            return
        }
        let maxOffset = max(0, scroll.contentSize.width - scroll.bounds.width)
        scroll.setContentOffset(
            CGPoint(x: max(0, min(offset, maxOffset)), y: 0), animated: false)
    }
}

/// One tab, as typography: [mono label] and, active only, [slot: dirty dot |
/// close ×]. The whole item is the click target; its context menu closes the
/// tab. Structure is decided at init from the immutable item; every model
/// change flows through the row's rebuild. Hover changes colour and alpha only:
/// a size change would re-enter layout.
private final class HeaderTabName: UIControl {
    let itemID: UUID
    let isActiveItem: Bool
    private let isDirtyItem: Bool
    private weak var strip: HeaderTabStrip?
    private let label = UILabel()
    /// Rest and hover renderings of the same string, built once so a hover can
    /// swap the label's tone without re-measuring it (identical font and text,
    /// so the width cannot change and no reflow can follow).
    private let restTitle: NSAttributedString
    private let hoverTitle: NSAttributedString
    /// The trailing slot's contents: the dot and the ×, cross-faded.
    private let slotDotView = UIView()
    private let slotCloseIcon = UIImageView()
    private let slotButton = UIButton(type: .custom)
    private var hovering = false

    /// The label's frame in this item's coordinates: what the row's underline
    /// tracks, and where the hover × is anchored.
    var labelFrame: CGRect { label.frame }

    /// The row places its underline from HERE, not from its own layout pass: a
    /// parent lays out before its children, so the row can only ever see a
    /// stale label frame.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard isActiveItem else { return }
        strip?.activeItemDidLayout()
    }

    /// Middle button: never a selection. The middle button reaches the row as
    /// an NSEvent through the glue (see `replayMiddleClick`), the one lane that
    /// closes the tab. Should a middle press also arrive as a touch, swallow it
    /// so the item neither selects itself nor closes twice.
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if event?.buttonMask.contains(.button(3)) == true { return false }
        let tracking = super.beginTracking(touch, with: event)
        if tracking { strip?.tabPressDidBegin(itemID) }
        return tracking
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        strip?.tabPressDidEnd()
    }

    /// The scroll view claiming a pan, or a drag lifting the item, both land
    /// here — the press is over either way.
    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        strip?.tabPressDidEnd()
    }

    init(item: TabItem, strip: HeaderTabStrip) {
        self.itemID = item.id
        self.isActiveItem = item.isActive
        self.isDirtyItem = item.isDirty
        self.strip = strip
        restTitle = Self.title(for: item)
        hoverTitle = Self.title(for: item, hovering: true)
        super.init(frame: .zero)
        registerForTraitChanges(UITraitCollection.chalkColorTraits) { (chip: Self, _: UITraitCollection) in
            chip.applyStyle()
        }

        label.attributedText = restTitle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // The hover × for a background tab sits past the item's trailing edge,
        // in the gap after the label, at the offset the active tab's slot
        // occupies. A subview so it travels with the item, never in the layout,
        // and `point(inside:)` claims its rectangle only while hovering, so the
        // row does not permanently swallow the window-drag space between names.
        clipsToBounds = false
        buildSlot(item: item)

        let padding = ChalkMetrics.tabLabelPadding
        var constraints = [
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: ChalkMetrics.tabMaxWidth),
        ]
        constraints += [
            slotButton.leadingAnchor.constraint(
                equalTo: label.trailingAnchor, constant: ChalkMetrics.tabInnerGap),
            slotButton.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ]
        if TabStripPolicy.slotIsReserved(isActive: item.isActive, isDirty: item.isDirty) {
            // The active tab's slot is INSIDE the item, so the item grows to
            // hold it.
            constraints.append(
                slotButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding))
        } else {
            // A background tab ends at its label: the slot hangs past the
            // trailing edge into the gap, where it appears on hover only.
            // Constraints do not require containment, and `clipsToBounds` is
            // off, so nothing clips it and nothing reflows when it shows.
            constraints.append(
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding))
        }
        NSLayoutConstraint.activate(constraints)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = item.name
        accessibilityIdentifier = "Tab-\(item.name)"

        addAction(UIAction { [weak strip] _ in strip?.onSelect?(item.id) }, for: .touchUpInside)

        // UIControl's built-in context-menu support (right-click).
        isContextMenuInteractionEnabled = true
        // Drag-reorder: press-and-move lifts the name (the system arbitrates
        // against the context-menu hold). Enabled explicitly — the default is
        // off for iPhone-style idioms.
        let drag = UIDragInteraction(delegate: strip)
        drag.isEnabled = true
        addInteraction(drag)

        // Pointer hover: the label brightens and a background tab
        // reveals its ×. No fill: there is no chip.
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:))))
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Mono label: a dim "folder/" prefix only where another open tab shares
    /// the filename, then the name. Active is medium weight; the one tab a
    /// browse click will replace slants (TabStripPolicy.isOblique).
    /// Colors are dynamic UIColors, re-applied on trait flips below.
    private static func title(for item: TabItem, hovering: Bool = false) -> NSAttributedString {
        let font = UIFont.chalkMono(
            size: ChalkMetrics.tabFontSize,
            weight: item.isActive ? .medium : .regular,
            oblique: TabStripPolicy.isOblique(isActive: item.isActive, isPreview: item.isPreview))
        let pathColor: UIColor = item.isActive ? .chalkTabPathActive : .chalkTabPathInactive
        let nameColor: UIColor = item.isActive || hovering
            ? .chalkTabLabelActive : .chalkTabLabelInactive
        // Truncation must live in the paragraph style: assigning attributedText
        // resets UILabel.lineBreakMode. The prefix shares the run, so it
        // truncates last (spec: CSS-style tail ellipsis over the whole run).
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

    /// The slot: dot OR × per TabStripPolicy.slotContent, cross-faded on slot
    /// hover for dirty tabs (that swap is how an unsaved tab is closed).
    /// Reserved in the layout on the active tab; parked in the following gap
    /// on a background tab, where it appears on hover only.
    private func buildSlot(item: TabItem) {
        slotDotView.backgroundColor = item.isActive
            ? .chalkTabDirtyDotActive : .chalkTabDirtyDotInactive
        slotDotView.layer.cornerRadius = ChalkMetrics.dirtyDotSize / 2
        slotDotView.isUserInteractionEnabled = false
        slotDotView.translatesAutoresizingMaskIntoConstraints = false

        slotCloseIcon.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: ChalkMetrics.s(TabStripMetrics.closeGlyph), weight: .semibold))
        slotCloseIcon.isUserInteractionEnabled = false
        slotCloseIcon.translatesAutoresizingMaskIntoConstraints = false

        slotButton.accessibilityLabel = "Close Tab"
        slotButton.addAction(
            UIAction { [weak strip] _ in strip?.onClose?(item.id) },
            for: .touchUpInside)
        slotButton.addGestureRecognizer(
            UIHoverGestureRecognizer(target: self, action: #selector(slotHoverChanged(_:))))
        addSubview(slotButton)
        slotButton.addSubview(slotDotView)
        slotButton.addSubview(slotCloseIcon)
        slotButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            slotButton.widthAnchor.constraint(equalToConstant: ChalkMetrics.tabSlotWidth),
            slotButton.heightAnchor.constraint(equalToConstant: ChalkMetrics.s(22)),
            slotDotView.centerXAnchor.constraint(equalTo: slotButton.centerXAnchor),
            slotDotView.centerYAnchor.constraint(equalTo: slotButton.centerYAnchor),
            slotDotView.widthAnchor.constraint(equalToConstant: ChalkMetrics.dirtyDotSize),
            slotDotView.heightAnchor.constraint(equalToConstant: ChalkMetrics.dirtyDotSize),
            slotCloseIcon.centerXAnchor.constraint(equalTo: slotButton.centerXAnchor),
            slotCloseIcon.centerYAnchor.constraint(equalTo: slotButton.centerYAnchor),
        ])
    }

    /// Label tone and slot alphas for the current state. Colour/alpha only,
    /// never a size change.
    private func applyStyle() {
        label.attributedText = hovering ? hoverTitle : restTitle
        switch TabStripPolicy.slotContent(isDirty: isDirtyItem) {
        case .dot:
            slotDotView.alpha = slotHovering ? 0 : 1
            slotCloseIcon.alpha = slotHovering ? 1 : 0
        case .close:
            // The × rests visible only on the active tab; a background tab's
            // appears on hover.
            slotDotView.alpha = 0
            slotCloseIcon.alpha = isActiveItem || hovering ? 1 : 0
        }
        // A background tab's whole slot lives in the gap and appears on hover.
        if !TabStripPolicy.slotIsReserved(isActive: isActiveItem, isDirty: isDirtyItem) {
            slotButton.alpha = hovering ? 1 : 0
        }
        slotCloseIcon.tintColor = slotHovering
            ? .chalkTabLabelActive
            : (isActiveItem ? .chalkTabIcon : .chalkTabIconDim)
    }

    private var slotHovering = false

    /// Claim the parked slot's rectangle too, but only while the pointer is
    /// already on this tab: otherwise the row would permanently own the gap
    /// between names, which is the window-drag surface on Mac.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        guard hovering || slotHovering,
              !TabStripPolicy.slotIsReserved(isActive: isActiveItem, isDirty: isDirtyItem) else { return false }
        return slotButton.frame.contains(point)
    }

    // Pressed state: colour/alpha only, never a size change.
    override var isHighlighted: Bool {
        get { super.isHighlighted }
        set {
            super.isHighlighted = newValue
            alpha = newValue ? 0.7 : 1.0
        }
    }

    @objc private func hoverChanged(_ recognizer: UIHoverGestureRecognizer) {
        let inside = recognizer.state == .began || recognizer.state == .changed
        guard inside != hovering else { return }
        hovering = inside
        crossFadeStyle()
    }

    /// Pointer over the slot itself: a dirty tab's dot cross-fades to the ×
    /// (same frame — color/alpha only), which is how an unsaved tab closes.
    @objc private func slotHoverChanged(_ recognizer: UIHoverGestureRecognizer) {
        let inside = recognizer.state == .began || recognizer.state == .changed
        guard inside != slotHovering else { return }
        slotHovering = inside
        crossFadeStyle()
    }

    /// Tone and alpha changes ride `motionTab`; the label's own tone swap is a
    /// cross-dissolve because an attributed-string change cannot tween.
    private func crossFadeStyle() {
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
            applyStyle()
            return
        }
        UIView.transition(with: label, duration: ChalkMetrics.motionTab,
                          options: [.transitionCrossDissolve, .beginFromCurrentState]) {
            self.label.attributedText = self.hovering ? self.hoverTitle : self.restTitle
        }
        UIView.animate(withDuration: ChalkMetrics.motionTab,
                       delay: 0, options: [.beginFromCurrentState]) {
            self.applyStyle()
        }
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"),
                         attributes: .destructive) { _ in
                    guard let self else { return }
                    self.strip?.onClose?(self.itemID)
                },
            ])
        })
    }
}
