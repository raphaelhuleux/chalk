import AppKit

/// Where a dragged tab will land over the editor: an accent wash over the half a new group would
/// take, or over the whole group the tab would join (docs/motion.md "Tab drag between groups").
/// Covers the pane host and never takes a click.
final class GroupDropOverlay: ThemedView {
    private let indicator = FlippedView()
    /// The rect the indicator shows, in this view; nil while hidden.
    private(set) var shownRect: CGRect?

    override init(frame: NSRect) {
        super.init(frame: frame)
        indicator.wantsLayer = true
        indicator.layer?.borderWidth = 1
        indicator.alphaValue = 0
        indicator.isHidden = true
        addSubview(indicator)
        refreshColors()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func refreshColors() {
        paint(indicator, background: NSColor.chalkAccent.withAlphaComponent(0.12))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            indicator.layer?.borderColor = NSColor.chalkAccent.withAlphaComponent(0.45).cgColor
        }
    }

    /// Show the indicator over `rect` (this view's coordinates), or hide it with nil. Appearing
    /// fades in on `motionFast`; a shown indicator glides to a new zone on `motionDropTarget`;
    /// Reduce Motion snaps.
    func show(_ rect: CGRect?) {
        guard rect != shownRect else { return }
        let wasShown = shownRect != nil
        shownRect = rect
        let animated = chalkMotionAllowed
        guard let rect else {
            guard animated else {
                indicator.alphaValue = 0
                indicator.isHidden = true
                return
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = ChalkMetrics.motionFast
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                indicator.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.shownRect == nil else { return }
                self.indicator.isHidden = true
            })
            return
        }
        guard animated else {
            indicator.frame = rect
            indicator.isHidden = false
            indicator.alphaValue = 1
            return
        }
        if !wasShown {
            indicator.frame = rect
            indicator.isHidden = false
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = wasShown ? ChalkMetrics.motionDropTarget : ChalkMetrics.motionFast
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if wasShown { indicator.animator().frame = rect }
            indicator.animator().alphaValue = 1
        }
    }
}
