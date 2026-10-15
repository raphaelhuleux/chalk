import ChalkKit
import UIKit

/// Spacing/size tokens for the native chrome (the Paper direction), as UIKit
/// points for this shell.
///
/// The spec values are `ChromeMetrics` in ChalkKit (Mac points). Catalyst runs
/// the iPad idiom, where UIKit points render at 77% on the Mac, so every token
/// here is the spec value × `displayScale` (1/0.77).
enum ChalkMetrics {
    /// iPad-idiom Catalyst draws UIKit content at 77%; inverse-scale the spec.
    static let displayScale: CGFloat = 1 / 0.77
    /// Spec value (Mac points) → UIKit points.
    static func s(_ value: CGFloat) -> CGFloat { value * displayScale }

    /// Not s()-scaled: it crosses into the page as CSS px via
    /// --chalk-chrome-top, and the webview is already scaled with the rest of
    /// the UI on Catalyst.
    static let editorRestingPad: CGFloat = CGFloat(ChromeMetrics.editorRestingPad)

    static let headerHeight: CGFloat = s(ChromeMetrics.headerHeight)

    static let sidebarWidth: CGFloat = s(ChromeMetrics.sidebarWidth)
    static let headerIconPointSize: CGFloat = s(ChromeMetrics.headerIconPointSize)
    static let sidebarRowFontSize: CGFloat = s(ChromeMetrics.sidebarRowFontSize)
    static let sectionHeaderFontSize: CGFloat = s(ChromeMetrics.sectionHeaderFontSize)
    static let sidebarCountFontSize: CGFloat = s(ChromeMetrics.sidebarCountFontSize)
    static let sidebarRowHeight: CGFloat = s(ChromeMetrics.sidebarRowHeight)
    static let tabFontSize: CGFloat = s(TabStripMetrics.fontSize)  // mono name row
    /// Trailing edge of the macOS traffic-light cluster, in MAC points
    /// (AX frames are AppKit coordinates).
    static let trafficLightsTrailingEdge: CGFloat = CGFloat(ChromeMetrics.trafficLightsTrailingEdge)
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
    static let sidebarListInset: CGFloat = s(ChromeMetrics.sidebarListInset)
    static let sidebarSectionTopMargin: CGFloat = s(ChromeMetrics.sidebarSectionTopMargin)
    static let sidebarSectionBottomMargin: CGFloat = s(ChromeMetrics.sidebarSectionBottomMargin)
    static let rowCornerRadius: CGFloat = s(ChromeMetrics.rowCornerRadius)
    static let footerButtonSize = CGSize(width: s(ChromeMetrics.footerButtonWidth),
                                         height: s(ChromeMetrics.footerButtonHeight))

    // Utility pill: the one place the chrome buttons live, a floating glass
    // capsule in the window's bottom-leading corner.
    static let utilityStripRadius: CGFloat = s(ChromeMetrics.utilityStripRadius)
    static let utilityStripPadding: CGFloat = s(ChromeMetrics.utilityStripPadding)
    static let footerPillMargin: CGFloat = s(ChromeMetrics.footerPillMargin)
    static var footerPillHeight: CGFloat { footerButtonSize.height + utilityStripPadding * 2 }

    // Quick Open palette
    static let paletteWidth: CGFloat = s(ChromeMetrics.paletteWidth)
    static let paletteRadius: CGFloat = s(ChromeMetrics.paletteRadius)
    static let paletteRowRadius: CGFloat = s(ChromeMetrics.paletteRowRadius)
    static let paletteResultFontSize: CGFloat = s(ChromeMetrics.paletteResultFontSize)
    static let paletteResultPathFontSize: CGFloat = s(ChromeMetrics.paletteResultPathFontSize)
    static let paletteHintFontSize: CGFloat = s(ChromeMetrics.paletteHintFontSize)
    static let paletteSearchFontSize: CGFloat = s(ChromeMetrics.paletteSearchFontSize)

    // Outline palette
    static let outlineRowHeight: CGFloat = s(ChromeMetrics.outlineRowHeight)
    static let outlineIndentUnit: CGFloat = s(ChromeMetrics.outlineIndentUnit)
    static let outlineRowFontSize: CGFloat = s(ChromeMetrics.outlineRowFontSize)
    static let outlineBadgeFontSize: CGFloat = s(ChromeMetrics.outlineBadgeFontSize)
    static let outlineEmptyHeight: CGFloat = s(ChromeMetrics.outlineEmptyHeight)

    static let dirtyDotSize: CGFloat = s(TabStripMetrics.dotSize)
    static let motionTab: TimeInterval = ChromeMetrics.motionTab
    static let motionFast: TimeInterval = ChromeMotion.fast // tab close, cover fades, tab-switch cross-fade, underline slide
    static let motionStandard: TimeInterval = ChromeMetrics.motionStandard
    /// The one sidebar clock (docs/motion.md): the Library column, the editor
    /// content translation and the AppKit strip's chip inset all ride this
    /// duration, ease-out. The strip receives it in the payload and never picks
    /// its own.
    static let motionSidebar: TimeInterval = ChromeMetrics.motionSidebar

    static let outlinePanelPushMinimumEditorWidth: CGFloat = s(ChromeMetrics.outlinePanelPushMinimumEditorWidth)

    /// Catalyst minimum window size (UIKit points): keeps the toolbar coherent
    /// (lights + a few tab names) and a usable editor column beside the Library.
    /// Shell-specific: not a spec token.
    static let minWindowSize = CGSize(width: 880, height: 560)

    static let settingsMinWindowSize = CGSize(width: s(ChromeMetrics.settingsMinWindowWidth),
                                              height: s(ChromeMetrics.settingsMinWindowHeight))
    static let settingsDefaultSize = CGSize(width: s(ChromeMetrics.settingsDefaultWidth),
                                            height: s(ChromeMetrics.settingsDefaultHeight))

    /// Settings rail row height, derived from the row font so the labels never
    /// clip. The max keeps it at s(30).
    static var settingsRailRowHeight: CGFloat {
        max(s(ChromeMetrics.settingsRailRowHeight),
            UIFont.systemFont(ofSize: sidebarRowFontSize).lineHeight + s(ChromeMetrics.settingsRailRowFontPadding))
    }
}
