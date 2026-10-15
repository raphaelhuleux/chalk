import AppKit
import ChalkKit

/// Spacing/size tokens for the native chrome (the Paper direction), in Mac
/// points: the spec values of `ChromeMetrics` and `TabStripMetrics`, unscaled.
/// The names match the Catalyst shell's `ChalkMetrics` so the ported tests
/// read the same tokens; the numbers are the spec's.
enum ChalkMetrics {
    /// AppKit draws at native resolution: no idiom scale. Kept so ported
    /// assertions that widen a tolerance on a scaled shell read 1 here.
    static let displayScale: CGFloat = 1

    /// CSS px, crossing into the page as --chalk-chrome-top.
    static let editorRestingPad: CGFloat = CGFloat(ChromeMetrics.editorRestingPad)

    /// The tab band's floor: the name row's own height. The live band is the
    /// titlebar's height when that is taller (`BandLayout.resolve`).
    static let headerHeight: CGFloat = CGFloat(ChromeMetrics.headerHeight)

    static let sidebarWidth: CGFloat = CGFloat(ChromeMetrics.sidebarWidth)
    static let headerIconPointSize: CGFloat = CGFloat(ChromeMetrics.headerIconPointSize)
    static let sidebarRowFontSize: CGFloat = CGFloat(ChromeMetrics.sidebarRowFontSize)
    static let sectionHeaderFontSize: CGFloat = CGFloat(ChromeMetrics.sectionHeaderFontSize)
    static let sidebarCountFontSize: CGFloat = CGFloat(ChromeMetrics.sidebarCountFontSize)
    static let sidebarRowHeight: CGFloat = CGFloat(ChromeMetrics.sidebarRowHeight)
    static let tabFontSize: CGFloat = TabStripMetrics.fontSize
    /// Trailing edge of the macOS traffic-light cluster (AX-measured).
    static let trafficLightsTrailingEdge: CGFloat = CGFloat(ChromeMetrics.trafficLightsTrailingEdge)
    /// Where the name row starts: past the lights, plus the gap. The same
    /// edge in full screen, where the lights are gone, so the row never jumps.
    static let tabStripLeading: CGFloat = trafficLightsTrailingEdge + TabStripMetrics.trafficLightGap

    /// Synthetic-oblique slant for the active preview tab: tan(12°). A ratio.
    static let obliqueSlant: CGFloat = TabStripMetrics.obliqueSlant

    // Tab name row (Paper).
    static let headerPadding: CGFloat = TabStripMetrics.trailingMargin
    static let tabGap: CGFloat = TabStripMetrics.gap
    static let tabLabelPadding: CGFloat = TabStripMetrics.labelPadding
    static let tabInnerGap: CGFloat = TabStripMetrics.innerGap
    static let tabMaxWidth: CGFloat = TabStripMetrics.maxTabWidth
    static let tabUnderlineHeight: CGFloat = TabStripMetrics.underlineHeight
    static let tabUnderlineGap: CGFloat = TabStripMetrics.underlineGap
    static let tabSlotWidth: CGFloat = TabStripMetrics.slotWidth
    static let newTabButtonSize = TabStripMetrics.newTabSize
    static let newTabGlyphSize: CGFloat = TabStripMetrics.newTabGlyph
    static let tabStripHeight: CGFloat = TabStripMetrics.stripHeight
    static let tabRowDividerGap: CGFloat = TabStripMetrics.dividerGap
    static let dirtyDotSize: CGFloat = TabStripMetrics.dotSize

    // Library (Paper).
    static let sidebarListInset: CGFloat = CGFloat(ChromeMetrics.sidebarListInset)
    static let sidebarSectionTopMargin: CGFloat = CGFloat(ChromeMetrics.sidebarSectionTopMargin)
    static let sidebarSectionBottomMargin: CGFloat = CGFloat(ChromeMetrics.sidebarSectionBottomMargin)
    static let rowCornerRadius: CGFloat = CGFloat(ChromeMetrics.rowCornerRadius)
    static let footerButtonSize = CGSize(width: ChromeMetrics.footerButtonWidth,
                                         height: ChromeMetrics.footerButtonHeight)

    // Utility pill.
    static let utilityStripRadius: CGFloat = CGFloat(ChromeMetrics.utilityStripRadius)
    static let utilityStripPadding: CGFloat = CGFloat(ChromeMetrics.utilityStripPadding)
    static let footerPillMargin: CGFloat = CGFloat(ChromeMetrics.footerPillMargin)
    static var footerPillHeight: CGFloat { footerButtonSize.height + utilityStripPadding * 2 }

    // Palettes.
    static let paletteWidth: CGFloat = CGFloat(ChromeMetrics.paletteWidth)
    static let paletteRadius: CGFloat = CGFloat(ChromeMetrics.paletteRadius)
    static let paletteRowRadius: CGFloat = CGFloat(ChromeMetrics.paletteRowRadius)
    static let paletteResultFontSize: CGFloat = CGFloat(ChromeMetrics.paletteResultFontSize)
    static let paletteResultPathFontSize: CGFloat = CGFloat(ChromeMetrics.paletteResultPathFontSize)
    static let paletteHintFontSize: CGFloat = CGFloat(ChromeMetrics.paletteHintFontSize)
    static let paletteSearchFontSize: CGFloat = CGFloat(ChromeMetrics.paletteSearchFontSize)
    static let outlineRowHeight: CGFloat = CGFloat(ChromeMetrics.outlineRowHeight)
    static let outlineIndentUnit: CGFloat = CGFloat(ChromeMetrics.outlineIndentUnit)
    static let outlineRowFontSize: CGFloat = CGFloat(ChromeMetrics.outlineRowFontSize)
    static let outlineBadgeFontSize: CGFloat = CGFloat(ChromeMetrics.outlineBadgeFontSize)
    static let outlineEmptyHeight: CGFloat = CGFloat(ChromeMetrics.outlineEmptyHeight)

    // Motion (docs/motion.md).
    static let motionTab: TimeInterval = ChromeMetrics.motionTab
    static let motionFast: TimeInterval = ChromeMotion.fast
    static let motionStandard: TimeInterval = ChromeMetrics.motionStandard
    static let motionSidebar: TimeInterval = ChromeMetrics.motionSidebar

    static let outlinePanelPushMinimumEditorWidth: CGFloat =
        CGFloat(ChromeMetrics.outlinePanelPushMinimumEditorWidth)

    /// Minimum window size: keeps a few tab names beside the lights and a
    /// usable editor column beside the Library. Shell-specific, Mac points.
    static let minWindowSize = CGSize(width: 680, height: 430)

    static let settingsMinWindowSize = CGSize(width: ChromeMetrics.settingsMinWindowWidth,
                                              height: ChromeMetrics.settingsMinWindowHeight)
    static let settingsDefaultSize = CGSize(width: ChromeMetrics.settingsDefaultWidth,
                                            height: ChromeMetrics.settingsDefaultHeight)

    /// Settings rail row height, derived from the row font so the labels never clip.
    static var settingsRailRowHeight: CGFloat {
        max(CGFloat(ChromeMetrics.settingsRailRowHeight),
            NSFont.systemFont(ofSize: sidebarRowFontSize).ascender
                - NSFont.systemFont(ofSize: sidebarRowFontSize).descender
                + CGFloat(ChromeMetrics.settingsRailRowFontPadding))
    }

    /// Spec value helper kept for ported call sites: the identity on AppKit.
    static func s(_ value: CGFloat) -> CGFloat { value }
}
