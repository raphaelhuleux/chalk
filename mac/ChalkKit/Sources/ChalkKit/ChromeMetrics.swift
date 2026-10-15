import Foundation

/// The native chrome's spacing and size tokens (the Paper direction), in Mac
/// points (CSS px at 1x), straight from the spec.
///
/// One declaration for both shells. The AppKit shell reads these raw; the
/// Catalyst shell's `ChalkMetrics` multiplies each by its iPad-idiom scale so
/// the two land at the same physical size. Tab-row tokens live in
/// `TabStripMetrics` and motion tokens in `ChromeMotion`.
public enum ChromeMetrics {
    /// One editor line between the chrome band and the resting first line, so
    /// the gap reads as a blank line: 17px font x 1.6 line-height
    /// (web/src/chalk-theme.css). CSS px: it crosses into the page as
    /// --chalk-chrome-top, so no shell scales it.
    public static let editorRestingPad: Double = 27

    /// Toolbar band (spec --toolbar-height 44). The system titlebar inset
    /// (traffic lights) folds into it.
    public static let headerHeight: Double = 44

    /// Default Library column width. The flat panel fills the column edge to
    /// edge, and the column stays user-resizable.
    public static let sidebarWidth: Double = 258
    /// Bounds for the resizable Library column and the outline panel.
    public static let sidebarWidthRange: ClosedRange<Double> = 220...560
    public static let headerIconPointSize: Double = 13 // chrome outline glyphs
    public static let sidebarRowFontSize: Double = 13  // --fs-row
    public static let sectionHeaderFontSize: Double = 13   // Paper area header, weight 600
    public static let sidebarCountFontSize: Double = 11    // Paper area count, faint
    public static let sidebarRowHeight: Double = 30    // --row-height
    /// Trailing edge of the macOS traffic-light cluster (AX-measured on the
    /// live window; AX frames are AppKit coordinates).
    public static let trafficLightsTrailingEdge: Double = 62

    // Library (Paper): a flat tone-on-tone list, flush with its column.
    /// The list's side inset inside the column: the selection pill's gap from
    /// the panel edge. Row content adds its own 8, so a row's icon lands 18
    /// from the edge, level with the area headers (spec .dshead margin).
    public static let sidebarListInset: Double = 10
    public static let sidebarSectionTopMargin: Double = 22     // above an area header
    public static let sidebarSectionBottomMargin: Double = 4   // header -> first row
    public static let rowCornerRadius: Double = 7      // --row-radius
    public static let footerButtonWidth: Double = 30   // .footer-btn
    public static let footerButtonHeight: Double = 26

    // Utility pill: the one place the chrome buttons live, a floating glass
    // capsule in the window's bottom-leading corner.
    public static let utilityStripRadius: Double = 11
    public static let utilityStripPadding: Double = 5
    public static let footerPillMargin: Double = 12    // inset from the window corner

    // Quick Open palette
    public static let paletteWidth: Double = 560       // --palette-width
    public static let paletteRadius: Double = 16       // --palette-radius
    // No top inset: the card centers on the window (both axes), so its
    // vertical position follows the window height instead of a constant.
    public static let paletteRowRadius: Double = 9     // --palette-row-radius
    public static let paletteResultFontSize: Double = 13  // --fs-result
    public static let paletteResultPathFontSize: Double = 11 // --fs-result-path
    public static let paletteHintFontSize: Double = 11 // --fs-hint
    public static let paletteSearchFontSize: Double = 15 // --fs-search-input

    // Outline palette (shares paletteWidth / paletteRadius / paletteRowRadius /
    // paletteSearchFontSize / paletteHintFontSize above).
    public static let outlineRowHeight: Double = 36    // single-line rows, denser than file rows
    public static let outlineIndentUnit: Double = 14   // per indent step
    public static let outlineRowFontSize: Double = 13  // = --fs-result
    public static let outlineBadgeFontSize: Double = 11 // "Theorem 3" / "Fig. 2"
    public static let outlineEmptyHeight: Double = 88  // empty-state band

    /// The outline panel pushes the editor while the column keeps at least
    /// this much text width, and overlays it below that.
    public static let outlinePanelPushMinimumEditorWidth: Double = 480

    /// Floor for the Settings window. Below this the rail and the
    /// trigger / replacement / options columns start clipping.
    public static let settingsMinWindowWidth: Double = 720
    public static let settingsMinWindowHeight: Double = 520
    /// Settings' opening size: the window's initial frame.
    public static let settingsDefaultWidth: Double = 900
    public static let settingsDefaultHeight: Double = 660
    /// Settings rail row height floor; the shell raises it to fit the row font.
    public static let settingsRailRowHeight: Double = 30
    public static let settingsRailRowFontPadding: Double = 14

    // Motion tokens not in ChromeMotion (docs/motion.md).
    public static let motionTab: TimeInterval = 0.10       // tab hover/dot-swap fades (spec caps at 120ms)
    public static let motionStandard: TimeInterval = 0.20  // zen chrome fade, sheets
    /// The one sidebar clock: the Library column, the editor content
    /// translation and the strip's chip inset all ride this duration, ease-out.
    public static let motionSidebar: TimeInterval = 0.22
}
