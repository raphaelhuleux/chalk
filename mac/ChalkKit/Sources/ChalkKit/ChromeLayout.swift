import Foundation
// Explicit: Swift 6 needs the module defining `.zero` default arguments
// imported by this file.
import CoreGraphics

/// What the windowed Mac titlebar strip should look like in a given state,
/// and (as `ChromeLayout.macStrip`) what the app last decided about it.
///
/// The strip's pixels live in ChalkAppKitGlue, which no test target links, so
/// only the app's posts are asserted: MacStripBridge's `postLeadingInset`,
/// `postVisibility` and `postFaded` record their decisions, and `forState` is
/// the oracle they are checked against.
public struct MacStripExpectation: Equatable, Sendable {
    /// The sidebar divider while the Library is tiled, 0 (the traffic lights)
    /// otherwise. In the reporting root's UIKit points, not Mac points.
    public var dividerX: CGFloat
    /// Whether the toolbar stands: only windowed, with the glue loaded. Zen
    /// keeps it standing, faded; full screen hands the row to the UIKit band.
    public var visible: Bool
    /// The fade. At rest only zen is faded; otherwise only an active
    /// auto-hide scroll run fades the strip (TabChromeOwnership).
    public var faded: Bool

    public init(dividerX: CGFloat, visible: Bool, faded: Bool) {
        self.dividerX = dividerX
        self.visible = visible
        self.faded = faded
    }

    /// The strip state a resting window in `window`/`sidebar`/`mode` must
    /// show. `dividerX` (the live editor column's leading edge) is echoed back
    /// when the state calls for an inset and zeroed otherwise.
    public static func forState(
        window: UIState.WindowMode,
        sidebar: UIState.SidebarState,
        mode: UIState.ChromeMode,
        glueAvailable: Bool,
        dividerX: CGFloat
    ) -> MacStripExpectation {
        // Zen closes the Library whatever `sidebar` asked for.
        let inset = (sidebar == .shown && mode != .zen) ? dividerX : 0
        // Zen keeps the toolbar standing so the window content never
        // resizes; full screen hands the tab row to the UIKit band.
        let visible = glueAvailable && window == .windowed
        // Only zen rests faded.
        let faded = mode == .zen
        return MacStripExpectation(dividerX: inset, visible: visible, faded: faded)
    }
}

/// The chrome's geometry for one window state, as a value.
///
/// `band` and `bandPaint` are separate because bugs have had a correct band
/// frame and a wrong painted region.
public struct ChromeLayout: Equatable, Sendable {
    public var state: UIState
    /// The window's content bounds, the frame every other rect is relative to.
    public var root: CGRect
    /// The tab band's frame.
    public var band: CGRect
    /// The band's OPAQUE region. Usually equal to `band`.
    public var bandPaint: CGRect
    /// A region cut out of `bandPaint`, so the paint runs behind the Library
    /// instead of over it. Nil when nothing is cut out.
    public var bandPaintHole: CGRect?
    /// The Library panel's frame, nil when hidden.
    public var libraryPanel: CGRect?
    /// The tab chips.
    public var tabStrip: CGRect
    /// Where the document's first line rests, in root coordinates.
    public var editorRestingTop: CGFloat
    /// One editor line: the gap the resting line keeps below the band.
    public var restingPad: CGFloat
    /// The Library row height, from the metrics table. Spec, not
    /// geometry: the Library header rules are stated in it.
    public var libraryRowHeight: CGFloat
    /// The spec gap between the active tab's label and its underline.
    public var underlineGap: CGFloat
    /// The floating utility pill's frame, `.zero` when the pill is hidden.
    public var footerPill: CGRect
    /// The spec offsets for the pill's resting corner (x = leading inset,
    /// y = bottom inset), which the live `footerPill` is asserted against.
    public var pillCorner: CGPoint
    /// The editor container's content view (the text column), in root
    /// coordinates.
    public var editorContent: CGRect
    /// Where the chrome reserving space above the text ends, in root
    /// coordinates: the band's live maxY, the top safe-area inset, or 0. Never
    /// computed from the same expression as `editorRestingTop`, or the
    /// resting-line rule collapses into a tautology.
    public var reserveTop: CGFloat
    /// The root's left safe-area inset: where content may begin when no
    /// Library column pushes it further in.
    public var safeLeading: CGFloat
    /// The top of the Library's first row, in root coordinates. Nil when the
    /// Library is closed or empty.
    public var libraryFirstRowTop: CGFloat?
    /// The top of the Library's first area header, in root coordinates, the
    /// datum the Library header rules use. Nil when closed or empty.
    public var libraryFirstHeaderTop: CGFloat?
    /// The Library list's scroll offset. Nil when the Library is closed.
    public var libraryScrollOffset: CGFloat?
    /// The ACTIVE tab's frame, nil when no tab is active (or no row hosted).
    public var activeChip: CGRect?
    /// The active tab's label and its accent underline, in root coordinates.
    /// Nil where the UIKit row is not the tab UI (windowed Mac).
    public var activeTabLabel: CGRect?
    public var activeTabUnderline: CGRect?
    /// The titlebar strip's state as the app last decided it, nil when the
    /// AppKit glue is unavailable.
    public var macStrip: MacStripExpectation?
    /// The outline panel's frame, nil when hidden.
    public var outlinePanel: CGRect?
    /// True when the panel floats over the text instead of pushing it: the
    /// column was too narrow to spare the width (see `outlinePanelPushMinimum`).
    public var outlinePanelIsOverlay: Bool
    /// The metrics table's floor for the pushed text column (spec).
    public var outlinePanelPushMinimum: CGFloat
    /// The trailing-edge cut-out of `bandPaint`, behind the outline panel.
    /// Nil when nothing is cut out there.
    public var bandPaintTrailingHole: CGRect?

    public init(state: UIState, root: CGRect, band: CGRect, bandPaint: CGRect,
                bandPaintHole: CGRect?, libraryPanel: CGRect?, tabStrip: CGRect,
                editorRestingTop: CGFloat, restingPad: CGFloat,
                libraryRowHeight: CGFloat = 34,
                underlineGap: CGFloat = 7,
                footerPill: CGRect = .zero,
                pillCorner: CGPoint = .zero,
                editorContent: CGRect = .zero,
                reserveTop: CGFloat = 0,
                safeLeading: CGFloat = 0,
                libraryFirstRowTop: CGFloat? = nil,
                libraryFirstHeaderTop: CGFloat? = nil,
                libraryScrollOffset: CGFloat? = nil,
                activeChip: CGRect? = nil,
                activeTabLabel: CGRect? = nil,
                activeTabUnderline: CGRect? = nil,
                macStrip: MacStripExpectation? = nil,
                outlinePanel: CGRect? = nil,
                outlinePanelIsOverlay: Bool = false,
                outlinePanelPushMinimum: CGFloat = 0,
                bandPaintTrailingHole: CGRect? = nil) {
        self.state = state
        self.root = root
        self.band = band
        self.bandPaint = bandPaint
        self.bandPaintHole = bandPaintHole
        self.libraryPanel = libraryPanel
        self.tabStrip = tabStrip
        self.editorRestingTop = editorRestingTop
        self.restingPad = restingPad
        self.libraryRowHeight = libraryRowHeight
        self.underlineGap = underlineGap
        self.footerPill = footerPill
        self.pillCorner = pillCorner
        self.editorContent = editorContent
        self.reserveTop = reserveTop
        self.safeLeading = safeLeading
        self.libraryFirstRowTop = libraryFirstRowTop
        self.libraryFirstHeaderTop = libraryFirstHeaderTop
        self.libraryScrollOffset = libraryScrollOffset
        self.activeChip = activeChip
        self.activeTabLabel = activeTabLabel
        self.activeTabUnderline = activeTabUnderline
        self.macStrip = macStrip
        self.outlinePanel = outlinePanel
        self.outlinePanelIsOverlay = outlinePanelIsOverlay
        self.outlinePanelPushMinimum = outlinePanelPushMinimum
        self.bandPaintTrailingHole = bandPaintTrailingHole
    }

    /// Whether opaque chrome actually covers any part of `rect`.
    ///
    /// Intersecting `bandPaint` is not enough: a cut-out may let the rect
    /// show through.
    public func paintCovers(_ rect: CGRect) -> Bool {
        let overlap = bandPaint.intersection(rect)
        guard !overlap.isNull, !overlap.isEmpty else { return false }
        if let hole = bandPaintHole, hole.contains(overlap) { return false }
        if let hole = bandPaintTrailingHole, hole.contains(overlap) { return false }
        return true
    }
}
