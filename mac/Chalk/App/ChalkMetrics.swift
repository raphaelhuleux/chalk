import ChalkKit
import UIKit

/// Spacing/size tokens for the native chrome (the Paper direction).
///
/// Spec values are Mac points (CSS px at 1x). Catalyst runs the iPad idiom,
/// where UIKit points render at 77% on the Mac, so every token is the spec
/// value × `displayScale` (1/0.77).
enum ChalkMetrics {
    /// iPad-idiom Catalyst draws UIKit content at 77%; inverse-scale the spec.
    static let displayScale: CGFloat = 1 / 0.77
    /// Spec value (Mac points) → UIKit points.
    static func s(_ value: CGFloat) -> CGFloat { value * displayScale }

    /// One editor line between the chrome band and the resting first line, so
    /// the gap reads as a blank line: 17px font x 1.6 line-height
    /// (web/src/chalk-theme.css). Not s()-scaled: it crosses into the page as
    /// CSS px via --chalk-chrome-top, and the webview is already scaled with
    /// the rest of the UI on Catalyst.
    static let editorRestingPad: CGFloat = 27

    /// Toolbar band (spec --toolbar-height 44). The system titlebar inset
    /// (traffic lights) folds into it.
    static let headerHeight: CGFloat = s(44)

    /// Default Library column width. The flat panel fills the column edge to
    /// edge, and the column stays user-resizable.
    static let sidebarWidth: CGFloat = s(258)
    static let headerIconPointSize: CGFloat = s(13) // chrome outline glyphs (~13pt, spec)
    static let sidebarRowFontSize: CGFloat = s(13)  // --fs-row
    static let sectionHeaderFontSize: CGFloat = s(13)   // Paper area header, weight 600
    static let sidebarCountFontSize: CGFloat = s(11)    // Paper area count, faint
    static let sidebarRowHeight: CGFloat = s(30)    // --row-height
    static let tabFontSize: CGFloat = s(TabStripMetrics.fontSize)  // mono name row
    /// Trailing edge of the macOS traffic-light cluster, in MAC points
    /// (AX-measured on the live window; AX frames are AppKit coordinates).
    static let trafficLightsTrailingEdge: CGFloat = 62
    /// The UIKit row's leading edge, used only in full screen (windowed tabs
    /// live in the NSToolbar): the AppKit strip's traffic-light gap past
    /// where the lights end.
    static let tabStripLeading: CGFloat = s(trafficLightsTrailingEdge + TabStripMetrics.trafficLightGap)

    /// Synthetic-oblique slant for the active preview tab: tan(12°). IBM Plex
    /// Mono ships no italic face here, so the upright one is sheared
    /// (UIFont.chalkMono `oblique:`, and the AppKit strip via `.obliqueness`).
    /// A ratio, never scaled.
    static let obliqueSlant: CGFloat = TabStripMetrics.obliqueSlant

    // Tab name row (Paper): a quiet mono text row on the editor surface. Active
    // is weight plus a short accent underline, inactive is muted.
    //
    // The numbers live in ChalkKit's TabStripMetrics, which the AppKit strip
    // reads raw (the titlebar is exempt from the 0.77× scale). Here each goes
    // through `s()` to land at the same physical size.
    static let headerPadding: CGFloat = s(TabStripMetrics.trailingMargin) // toolbar side padding
    static let tabGap: CGFloat = s(TabStripMetrics.gap)
    static let tabLabelPadding: CGFloat = s(TabStripMetrics.labelPadding)
    static let tabInnerGap: CGFloat = s(TabStripMetrics.innerGap)
    static let tabMaxWidth: CGFloat = s(TabStripMetrics.maxTabWidth)
    static let tabUnderlineHeight: CGFloat = s(TabStripMetrics.underlineHeight)
    static let tabUnderlineGap: CGFloat = s(TabStripMetrics.underlineGap)
    static let tabSlotWidth: CGFloat = s(TabStripMetrics.slotWidth)
    static let newTabButtonSize = CGSize(width: s(TabStripMetrics.newTabSize.width),
                                        height: s(TabStripMetrics.newTabSize.height))
    static let newTabGlyphSize: CGFloat = s(TabStripMetrics.newTabGlyph)
    static let tabStripHeight: CGFloat = s(TabStripMetrics.stripHeight)
    static let tabRowDividerGap: CGFloat = s(TabStripMetrics.dividerGap)

    // Library (Paper): a flat tone-on-tone list, flush with its column.
    /// The list's side inset inside the column: the selection pill's gap from
    /// the panel edge. Row content adds its own 8, so a row's icon lands 18
    /// from the edge, level with the area headers (spec .dshead margin).
    static let sidebarListInset: CGFloat = s(10)
    static let sidebarSectionTopMargin: CGFloat = s(22)     // above an area header
    static let sidebarSectionBottomMargin: CGFloat = s(4)   // header -> first row
    static let rowCornerRadius: CGFloat = s(7)      // --row-radius
    static let footerButtonSize = CGSize(width: s(30), height: s(26)) // .footer-btn

    // Utility pill: the one place the chrome buttons live, a floating glass
    // capsule in the window's bottom-leading corner.
    static let utilityStripRadius: CGFloat = s(11)
    static let utilityStripPadding: CGFloat = s(5)
    static let footerPillMargin: CGFloat = s(12)    // inset from the window corner
    static var footerPillHeight: CGFloat { footerButtonSize.height + utilityStripPadding * 2 }

    // Quick Open palette
    static let paletteWidth: CGFloat = s(560)       // --palette-width
    static let paletteRadius: CGFloat = s(16)       // --palette-radius
    // No top inset: the card centers on the window (both axes), so its
    // vertical position follows the window height instead of a constant.
    static let paletteRowRadius: CGFloat = s(9)     // --palette-row-radius
    static let paletteResultFontSize: CGFloat = s(13)  // --fs-result
    static let paletteResultPathFontSize: CGFloat = s(11) // --fs-result-path
    static let paletteHintFontSize: CGFloat = s(11) // --fs-hint
    static let paletteSearchFontSize: CGFloat = s(15) // --fs-search-input

    // Outline palette (shares paletteWidth / paletteRadius / paletteRowRadius /
    // paletteSearchFontSize / paletteHintFontSize above).
    static let outlineRowHeight: CGFloat = s(36)    // single-line rows, denser than file rows
    static let outlineIndentUnit: CGFloat = s(14)   // per indent step
    static let outlineRowFontSize: CGFloat = s(13)  // = --fs-result
    static let outlineBadgeFontSize: CGFloat = s(11) // "Theorem 3" / "Fig. 2"
    static let outlineEmptyHeight: CGFloat = s(88)  // empty-state band

    static let dirtyDotSize: CGFloat = s(TabStripMetrics.dotSize)
    static let motionTab: TimeInterval = 0.10       // tab hover/dot-swap fades (spec caps at 120ms)
    static let motionFast: TimeInterval = ChromeMotion.fast // tab close, cover fades, tab-switch cross-fade, underline slide
    static let motionStandard: TimeInterval = 0.20  // zen chrome fade, sheets
    /// The one sidebar clock (docs/motion.md): the Library column, the editor
    /// content translation and the AppKit strip's chip inset all ride this
    /// duration, ease-out. The strip receives it in the payload and never picks
    /// its own.
    static let motionSidebar: TimeInterval = 0.22

    /// The outline panel pushes the editor while the column keeps at least
    /// this much text width, and overlays it below that. Spec points: `s(480)`
    /// lands at 480 Mac points.
    static let outlinePanelPushMinimumEditorWidth: CGFloat = s(480)

    /// Catalyst minimum window size (UIKit points): keeps the toolbar coherent
    /// (lights + a few tab names) and a usable editor column beside the Library.
    static let minWindowSize = CGSize(width: 880, height: 560)

    /// Floor for the Settings window. Below this the rail and the
    /// trigger / replacement / options columns start clipping. Spec points,
    /// so it goes through `s()` like every other token.
    static let settingsMinWindowSize = CGSize(width: s(720), height: s(520))

    /// Settings' opening size: the window's initial frame. Spec points, so the
    /// box scales with its contents.
    static let settingsDefaultSize = CGSize(width: s(900), height: s(660))

    /// Settings rail row height, derived from the row font so the labels never
    /// clip. The max keeps it at s(30).
    static var settingsRailRowHeight: CGFloat {
        max(s(30), UIFont.systemFont(ofSize: sidebarRowFontSize).lineHeight + s(14))
    }
}
