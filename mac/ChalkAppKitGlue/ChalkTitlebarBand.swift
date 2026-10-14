import AppKit

/// Paint-only titlebar cover: fills the titlebar with `StripColor.paperFill`
/// from the name row's baseline up, minus the Library and outline panels.
/// The titlebar is transparent and the editor runs full-bleed beneath it, so
/// without an opaque cover scrolled text would show between the tab names.
/// Installed under the toolbar view by ChalkToolbarController; takes no clicks.
final class ChalkTitlebarBackgroundView: NSView {
    /// Sidebar/editor divider X in window coords (MAC points); 0 = hidden.
    /// The Library's cut-out reaches this far.
    private var dividerX: CGFloat = 0
    /// The outline panel's width from the window's trailing edge (MAC
    /// points); 0 = hidden.
    private var outlineWidth: CGFloat = 0
    /// Distance from the titlebar's bottom to the chips' baseline (y-up),
    /// fed by ChalkToolbarController after every strip layout.
    private var chipBaseline: CGFloat = 0

    init() {
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Pushed by ChalkToolbarController, which owns the single divider-geometry
    /// observer for all three titlebar views.
    func setDividerGeometry(dividerX: CGFloat, outlineWidth: CGFloat) {
        guard abs(self.dividerX - dividerX) > 0.5
            || abs(self.outlineWidth - outlineWidth) > 0.5 else { return }
        self.dividerX = dividerX
        self.outlineWidth = outlineWidth
        needsDisplay = true
    }

    func setChipBaseline(_ baseline: CGFloat) {
        let clamped = max(0, baseline)
        guard abs(chipBaseline - clamped) > 0.5 else { return }
        chipBaseline = clamped
        needsDisplay = true
    }

    /// Pure paint — every click stays AppKit's.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // The shape is TitlebarBandGeometry's call (ChalkKit source compiled
        // into this bundle), so tests can reach it. Band minus the panels'
        // rectangles, as one even-odd path.
        let paint = TitlebarBandGeometry.paint(
            bounds: bounds, chipBaseline: chipBaseline, libraryWidth: dividerX,
            outlineWidth: outlineWidth)
        guard !paint.band.isEmpty, paint.band.intersects(dirtyRect) else { return }

        StripColor.paperFill.setFill()
        guard paint.libraryHole != nil || paint.outlineHole != nil else {
            paint.band.intersection(dirtyRect).fill()
            return
        }
        // Clip to the band first: a hole extends below the band, and under
        // even-odd the part outside the band is crossed once, so it would fill
        // as a sliver across the sidebar.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: paint.band).setClip()

        let path = NSBezierPath(rect: paint.band)
        if let hole = paint.libraryHole {
            path.append(NSBezierPath(rect: hole))
        }
        if let hole = paint.outlineHole {
            path.append(NSBezierPath(rect: hole))
        }
        path.windingRule = .evenOdd
        path.fill()
    }
}

/// The Library's slice of the titlebar.
///
/// The Library panel runs under the titlebar, but `NSToolbarView` spans the
/// window, so clicks on sidebar rows in the top band never reach UIKit. This
/// view claims only the Library's rectangle (left of the divider, below the
/// traffic lights) and forwards clicks as `titlebarBandClick` (top-left MAC
/// points, tagged with `windowNumber`); the bound scene replays them as taps.
/// A press that travels more than 4pt becomes `NSWindow.performDrag`.
final class ChalkTitlebarBandView: NSView {
    /// Identity runs through this window, never `self.window` (full screen
    /// rehosts the toolbar into an NSToolbarFullScreenWindow).
    weak var attachedWindow: NSWindow?

    /// Sidebar/editor divider X in window coords (MAC points); 0 = the Library
    /// is hidden, and the band then claims nothing at all.
    private var dividerX: CGFloat = 0

    init() {
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Pushed by ChalkToolbarController, which owns the single divider-geometry
    /// observer for all three titlebar views.
    func setDividerX(_ x: CGFloat) { dividerX = x }

    /// Bottom edge of the traffic lights in this view's coordinates (y-up, so
    /// "below" is a smaller y). Nil when the lights are hidden (full screen):
    /// the band then claims nothing.
    private var trafficLightsBottom: CGFloat? {
        guard let button = attachedWindow?.standardWindowButton(.closeButton),
              let superview = button.superview, button.window != nil, !button.isHidden
        else { return nil }
        return convert(button.frame, from: superview).minY
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { postPointer(inside: true) }
    override func mouseExited(with event: NSEvent) { postPointer(inside: false) }

    private func postPointer(inside: Bool) {
        guard let number = attachedWindow?.windowNumber else { return }
        NotificationCenter.default.post(
            name: TabStripBridge.titlebarPointerInBand, object: nil,
            userInfo: [TabStripBridge.insideKey: inside,
                       TabStripBridge.windowNumberKey: number])
    }

    /// Claim only the Library's rectangle; everything else stays AppKit's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard dividerX > 0, let lightsBottom = trafficLightsBottom else { return nil }
        let local = convert(point, from: superview)
        guard local.x >= 0, local.x <= dividerX,
              local.y >= 0, local.y <= lightsBottom
        else { return nil }
        return self
    }

    /// Without this the window server starts an async window drag on press and
    /// the tracking loop reads a frozen `locationInWindow`.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Press → tracking loop → forward the click, or hand the gesture back to
    /// the window as a drag. `mouseDragged` never fires for titlebar-hosted
    /// views, so the loop dequeues the stream itself.
    override func mouseDown(with event: NSEvent) {
        guard let window = attachedWindow ?? window else { return }
        let start = event.locationInWindow
        while true {
            guard let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture, inMode: .eventTracking, dequeue: true)
            else { return } // window died mid-press; looping would busy-spin
            if next.type == .leftMouseUp {
                postClick(at: next.locationInWindow, in: window)
                return
            }
            // 4pt of travel: moving the window, not clicking a row.
            if hypot(next.locationInWindow.x - start.x,
                     next.locationInWindow.y - start.y) > 4 {
                window.performDrag(with: event)
                return
            }
        }
    }

    /// Bottom-left window coords to the top-left MAC points the UIKit side
    /// expects; it scales them by `ChalkMetrics.displayScale` on arrival.
    private func postClick(at location: NSPoint, in window: NSWindow) {
        NotificationCenter.default.post(
            name: TabStripBridge.titlebarBandClick, object: nil,
            userInfo: [
                TabStripBridge.xKey: location.x,
                TabStripBridge.yKey: window.frame.height - location.y,
                TabStripBridge.windowNumberKey: window.windowNumber,
            ])
    }
}
