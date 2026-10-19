import AppKit

/// Spacing, size and motion tokens for the native chrome (the Paper
/// direction), in Mac points (CSS px at 1x), straight from the spec.
enum ChalkMetrics {
    /// One editor line between the chrome band and the resting first line, so
    /// the gap reads as a blank line: 17px font x 1.6 line-height
    /// (web/src/chalk-theme.css). CSS px: it crosses into the page as
    /// --chalk-chrome-top.
    static let editorRestingPad: CGFloat = 27

    /// Toolbar band (spec --toolbar-height 44). The live band is the
    /// titlebar's height when that is taller (`BandLayout.resolve`).
    static let headerHeight: CGFloat = 44

    /// Default Library column width. The flat panel fills the column edge to
    /// edge, and the column stays user-resizable.
    static let sidebarWidth: CGFloat = 258
    /// Bounds for the resizable Library column and the outline panel.
    static let sidebarWidthRange: ClosedRange<CGFloat> = 220...560
    static let headerIconPointSize: CGFloat = 13 // chrome outline glyphs
    static let sidebarRowFontSize: CGFloat = 13  // --fs-row
    static let sectionHeaderFontSize: CGFloat = 13   // Paper area header, weight 600
    static let sidebarCountFontSize: CGFloat = 11    // Paper area count, faint
    static let sidebarRowHeight: CGFloat = 30    // --row-height
    /// Trailing edge of the macOS traffic-light cluster (AX-measured on the
    /// live window).
    static let trafficLightsTrailingEdge: CGFloat = 62
    /// Gap between the traffic lights and the first name.
    static let trafficLightGap: CGFloat = 16
    /// Where the name row starts: past the lights, plus the gap. The same
    /// edge in full screen, where the lights are gone, so the row never jumps.
    static let tabStripLeading: CGFloat = trafficLightsTrailingEdge + trafficLightGap

    // Tab name row (Paper).
    /// The name row's own height.
    static let tabStripHeight: CGFloat = 46
    /// Gap kept clear at the titlebar's trailing edge.
    static let headerPadding: CGFloat = 14
    /// Between name items.
    static let tabGap: CGFloat = 12
    /// Inside each item, both sides.
    static let tabLabelPadding: CGFloat = 8
    /// Label → trailing slot.
    static let tabInnerGap: CGFloat = 8
    /// Label truncation cap.
    static let tabMaxWidth: CGFloat = 290
    /// The active name's accent underline…
    static let tabUnderlineHeight: CGFloat = 2
    /// …and its distance below the label.
    static let tabUnderlineGap: CGFloat = 7
    /// The trailing slot that holds the dot or the close ×.
    static let tabSlotWidth: CGFloat = 14
    /// The trailing "+" button's box…
    static let newTabButtonSize = CGSize(width: 28, height: 34)
    /// …and the ink inside it (NewTabGlyphSizeTests measures the ink).
    static let newTabGlyphSize: CGFloat = 10
    /// The overflow chevron's symbol point size.
    static let overflowGlyphSize: CGFloat = 10
    /// The close ×'s symbol point size, inside the trailing slot.
    static let closeGlyphSize: CGFloat = 7.5
    /// Mono name size (spec value).
    static let tabFontSize: CGFloat = 12
    /// Divider → first item edge; with the item's 8pt padding the first label
    /// lands 22pt past the divider.
    static let tabRowDividerGap: CGFloat = 14
    /// Unsaved dot.
    static let dirtyDotSize: CGFloat = 5
    /// tan(12°): the preview tab's synthetic slant (no italic face is
    /// bundled). A ratio, not a length.
    static let obliqueSlant: CGFloat = 0.2126

    // Library (Paper): a flat tone-on-tone list, flush with its column.
    /// The list's side inset inside the column: the selection pill's gap from
    /// the panel edge. Row content adds its own 8, so a row's icon lands 18
    /// from the edge, level with the area headers (spec .dshead margin).
    static let sidebarListInset: CGFloat = 10
    static let sidebarSectionTopMargin: CGFloat = 22     // above an area header
    static let sidebarSectionBottomMargin: CGFloat = 4   // header -> first row
    static let rowCornerRadius: CGFloat = 7      // --row-radius
    static let footerButtonSize = CGSize(width: 30, height: 26) // .footer-btn

    // Utility pill: the one place the chrome buttons live, a floating glass
    // capsule in the window's bottom-leading corner.
    static let utilityStripRadius: CGFloat = 11
    static let utilityStripPadding: CGFloat = 5
    static let footerPillMargin: CGFloat = 12    // inset from the window corner
    static var footerPillHeight: CGFloat { footerButtonSize.height + utilityStripPadding * 2 }

    // Quick Open palette. No top inset: the card centers on the window (both
    // axes), so its vertical position follows the window height.
    static let paletteWidth: CGFloat = 560       // --palette-width
    static let paletteRadius: CGFloat = 16       // --palette-radius
    static let paletteRowRadius: CGFloat = 9     // --palette-row-radius
    static let paletteResultFontSize: CGFloat = 13  // --fs-result
    static let paletteResultPathFontSize: CGFloat = 11 // --fs-result-path
    static let paletteHintFontSize: CGFloat = 11 // --fs-hint
    static let paletteSearchFontSize: CGFloat = 15 // --fs-search-input

    // Outline palette and panel (share the palette tokens above).
    static let outlineRowHeight: CGFloat = 36    // single-line rows, denser than file rows
    static let outlineIndentUnit: CGFloat = 14   // per indent step
    static let outlineRowFontSize: CGFloat = 13  // = --fs-result
    static let outlineBadgeFontSize: CGFloat = 11 // "Theorem 3" / "Fig. 2"
    static let outlineEmptyHeight: CGFloat = 88  // empty-state band
    /// The outline panel pushes the editor while the column keeps at least
    /// this much text width, and overlays it below that.
    static let outlinePanelPushMinimumEditorWidth: CGFloat = 480
    /// Each pane of a split editor keeps at least this width while the column can spare two.
    static let splitMinimumPaneWidth: CGFloat = 320

    // Motion (docs/motion.md, Tokens).
    /// Tab hover and dot-swap fades (spec caps at 120ms).
    static let motionTab: TimeInterval = 0.10
    /// Tab close, cover fades, the tab-switch cross-fade and the underline slide.
    static let motionFast: TimeInterval = 0.15
    /// Zen chrome fade, sheets.
    static let motionStandard: TimeInterval = 0.20
    /// The one sidebar clock: the Library column, the editor content
    /// translation and the strip's chip inset all ride this duration, ease-out.
    static let motionSidebar: TimeInterval = 0.22
    /// The auto-hide slide and fade.
    static let motionAutoHide: TimeInterval = 0.22

    /// Minimum window size: keeps a few tab names beside the lights and a
    /// usable editor column beside the Library.
    static let minWindowSize = CGSize(width: 680, height: 430)

    /// Floor for the Settings window. Below this the rail and the
    /// trigger / replacement / options columns start clipping.
    static let settingsMinWindowSize = CGSize(width: 720, height: 520)
    /// Settings' opening size: the window's initial frame.
    static let settingsDefaultSize = CGSize(width: 900, height: 660)

    /// Settings rail row height: a 30pt floor, raised to fit the row font so
    /// the labels never clip.
    static var settingsRailRowHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: sidebarRowFontSize)
        return max(30, font.ascender - font.descender + 14)
    }
}
