import AppKit
import ChalkKit

/// The editor's content area: one pane filling it, or two side by side with a draggable seam.
/// Panes are placed by frame in `layout()`, not by constraints: the seam moves on every drag and
/// window resize, and a constraint constant rewritten from `viewDidLayout` re-enters layout.
/// Surfaces pin to their pane with constraints, as they did to the content view.
final class EditorPaneHostView: ThemedView {
    enum Side {
        case leading, trailing
        var other: Side { self == .leading ? .trailing : .leading }
    }

    let leadingPane = FlippedView()
    let trailingPane = FlippedView()
    /// Straddles the seam, above both panes, so a drag on the visible edge catches it from
    /// either side.
    let divider = ColumnResizeGrip()
    private let seam = FlippedView()

    /// Two panes, or one.
    var isSplit = false {
        didSet { if isSplit != oldValue { needsLayout = true } }
    }
    /// The pane that fills the area without a split. The other one is hidden then, so a surface
    /// can stay in the pane it had when the split closed.
    var soloSide: Side = .leading {
        didSet { if soloSide != oldValue { needsLayout = true } }
    }
    /// The leading pane's share of the width (`Preferences.splitFraction`).
    var fraction: CGFloat = 0.5 {
        didSet {
            fraction = SplitLayout.clampedFraction(fraction)
            if fraction != oldValue { needsLayout = true }
        }
    }

    /// The leading pane's width in the current layout, for a drag's starting point.
    var leadingWidth: CGFloat { leadingPane.frame.width }

    func pane(_ side: Side) -> NSView { side == .leading ? leadingPane : trailingPane }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for pane in [leadingPane, trailingPane] {
            pane.translatesAutoresizingMaskIntoConstraints = true
            pane.autoresizingMask = []
            addSubview(pane)
        }
        seam.wantsLayer = true
        addSubview(seam)
        divider.showsHoverLine = true
        addSubview(divider)
        refreshColors()
        needsLayout = true
    }

    override func refreshColors() {
        seam.chalkSetLayerBackground(.chalkBorderHard, under: effectiveAppearance)
    }

    override func layout() {
        super.layout()
        trailingPane.isHidden = !isSplit && soloSide == .leading
        leadingPane.isHidden = !isSplit && soloSide == .trailing
        seam.isHidden = !isSplit
        divider.isHidden = !isSplit
        guard isSplit else {
            pane(soloSide).frame = bounds
            return
        }
        let width = SplitLayout.leadingWidth(columnWidth: bounds.width, fraction: fraction,
                                             minimumPane: ChalkMetrics.splitMinimumPaneWidth)
        leadingPane.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        trailingPane.frame = CGRect(x: width, y: 0, width: bounds.width - width, height: bounds.height)
        seam.frame = CGRect(x: width - 0.5, y: 0, width: 1, height: bounds.height)
        divider.frame = CGRect(x: width - 6, y: 0, width: 12, height: bounds.height)
    }
}
