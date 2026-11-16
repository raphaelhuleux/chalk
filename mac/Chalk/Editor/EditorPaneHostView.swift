import AppKit
import ChalkKit

/// The editor's content area: one pane per tab group, side by side, with a draggable seam between
/// neighbours. Panes are placed by frame in `layout()`, not by constraints: the seams move on
/// every drag and window resize, and a constraint constant rewritten from `viewDidLayout`
/// re-enters layout. Surfaces pin to their pane with constraints.
final class EditorPaneHostView: ThemedView {
    /// Leading to trailing; each group owns its pane, so adding or closing a group never moves
    /// another group's surface between superviews.
    private(set) var panes: [NSView] = []
    /// `grips[i]` straddles the seam between `panes[i]` and `panes[i + 1]`, above both, so a drag
    /// on the visible edge catches it from either side.
    private(set) var grips: [ColumnResizeGrip] = []
    private var seams: [FlippedView] = []
    /// The tab-drag drop indicator, above the panes and grips.
    let dropOverlay = GroupDropOverlay()

    /// How the width is shared. The owner sets it on structural changes; grip drags write it.
    var layoutModel: EditorGroupsLayout = .single {
        didSet { if layoutModel != oldValue { needsLayout = true } }
    }
    /// The panes' frames moved (resize, seam drag, group added or closed), after the frames are set.
    var onPaneFramesChanged: (() -> Void)?
    private var lastPaneFrames: [CGRect] = []
    private var dragStartWidths: [CGFloat] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(dropOverlay)
        refreshColors()
        needsLayout = true
    }

    /// Show `newPanes`, leading to trailing. Panes not in the list leave the view (with whatever
    /// they host); kept ones stay put in the hierarchy.
    func setPanes(_ newPanes: [NSView]) {
        guard newPanes.map(ObjectIdentifier.init) != panes.map(ObjectIdentifier.init) else { return }
        for pane in panes where !newPanes.contains(where: { $0 === pane }) { pane.removeFromSuperview() }
        for pane in newPanes where pane.superview !== self {
            pane.translatesAutoresizingMaskIntoConstraints = true
            pane.autoresizingMask = []
            // Under every seam, grip and the overlay; above anything else the owner put here.
            addSubview(pane, positioned: .below, relativeTo: seams.first ?? grips.first ?? dropOverlay)
        }
        panes = newPanes
        let seamCount = max(0, newPanes.count - 1)
        while seams.count > seamCount { seams.removeLast().removeFromSuperview() }
        while grips.count > seamCount { grips.removeLast().removeFromSuperview() }
        while seams.count < seamCount {
            let seam = FlippedView()
            seam.wantsLayer = true
            addSubview(seam, positioned: .below, relativeTo: grips.first ?? dropOverlay)
            seams.append(seam)
        }
        while grips.count < seamCount {
            let grip = ColumnResizeGrip()
            grip.showsHoverLine = true
            wire(grip, seam: grips.count)
            addSubview(grip, positioned: .below, relativeTo: dropOverlay)
            grips.append(grip)
        }
        refreshColors()
        needsLayout = true
    }

    private func wire(_ grip: ColumnResizeGrip, seam: Int) {
        grip.onDragBegan = { [weak self] in
            self?.dragStartWidths = self?.panes.map(\.frame.width) ?? []
        }
        grip.onDragged = { [weak self] dx in
            guard let self, self.dragStartWidths.count == self.panes.count else { return }
            self.layoutModel = EditorGroupsLayout.resized(
                startWidths: self.dragStartWidths, seam: seam, by: dx,
                minimum: ChalkMetrics.groupMinimumWidth)
        }
    }

    override func refreshColors() {
        for seam in seams { paint(seam, background: .chalkBorderHard) }
    }

    override func layout() {
        super.layout()
        dropOverlay.frame = bounds
        let widths = layoutModel.fitted(toCount: panes.count)
            .widths(columnWidth: bounds.width, minimum: ChalkMetrics.groupMinimumWidth)
        var x: CGFloat = 0
        for (i, pane) in panes.enumerated() {
            pane.frame = CGRect(x: x, y: 0, width: widths[i], height: bounds.height)
            x += widths[i]
            guard i < seams.count else { continue }
            seams[i].frame = CGRect(x: x - 0.5, y: 0, width: 1, height: bounds.height)
            grips[i].frame = CGRect(x: x - 6, y: 0, width: 12, height: bounds.height)
        }
        let frames = panes.map(\.frame)
        if frames != lastPaneFrames {
            lastPaneFrames = frames
            onPaneFramesChanged?()
        }
    }
}
