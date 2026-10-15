import Foundation
import CoreGraphics

/// A `ChromeLayout` as a plain record, in Mac points, for the reference file
/// the AppKit port is measured against (plan: "UI parity method").
///
/// Every rect is divided by `scale` on the way in, so a layout read off the
/// Catalyst shell (iPad-idiom points, 1/0.77 of a Mac point) and one read off
/// the AppKit shell (Mac points) compare directly. Fields are optional where
/// the layout's are, and absent fields encode as absent, so the JSON shows
/// what each cell actually had.
public struct ChromeLayoutRecord: Codable, Equatable, Sendable {
    public struct Rect: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(_ rect: CGRect, scale: CGFloat) {
            x = Double(rect.origin.x / scale)
            y = Double(rect.origin.y / scale)
            width = Double(rect.size.width / scale)
            height = Double(rect.size.height / scale)
        }

        public var cgRect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    public var id: String
    public var root: Rect
    public var band: Rect
    public var bandPaint: Rect
    public var bandPaintHole: Rect?
    public var bandPaintTrailingHole: Rect?
    public var libraryPanel: Rect?
    public var tabStrip: Rect
    public var editorRestingTop: Double
    public var restingPad: Double
    public var reserveTop: Double
    public var safeLeading: Double
    public var footerPill: Rect
    public var editorContent: Rect
    public var libraryFirstRowTop: Double?
    public var libraryFirstHeaderTop: Double?
    public var activeChip: Rect?
    public var activeTabLabel: Rect?
    public var activeTabUnderline: Rect?
    public var outlinePanel: Rect?
    public var outlinePanelIsOverlay: Bool
    /// The strip's decided divider inset, in Mac points, when the shell
    /// records one.
    public var stripDividerX: Double?

    public init(_ layout: ChromeLayout, scale: CGFloat) {
        func length(_ value: CGFloat) -> Double { Double(value / scale) }
        id = layout.state.id
        root = Rect(layout.root, scale: scale)
        band = Rect(layout.band, scale: scale)
        bandPaint = Rect(layout.bandPaint, scale: scale)
        bandPaintHole = layout.bandPaintHole.map { Rect($0, scale: scale) }
        bandPaintTrailingHole = layout.bandPaintTrailingHole.map { Rect($0, scale: scale) }
        libraryPanel = layout.libraryPanel.map { Rect($0, scale: scale) }
        tabStrip = Rect(layout.tabStrip, scale: scale)
        editorRestingTop = length(layout.editorRestingTop)
        // CSS px, never scaled (ChromeMetrics.editorRestingPad).
        restingPad = Double(layout.restingPad)
        reserveTop = length(layout.reserveTop)
        safeLeading = length(layout.safeLeading)
        footerPill = Rect(layout.footerPill, scale: scale)
        editorContent = Rect(layout.editorContent, scale: scale)
        libraryFirstRowTop = layout.libraryFirstRowTop.map(length)
        libraryFirstHeaderTop = layout.libraryFirstHeaderTop.map(length)
        activeChip = layout.activeChip.map { Rect($0, scale: scale) }
        activeTabLabel = layout.activeTabLabel.map { Rect($0, scale: scale) }
        activeTabUnderline = layout.activeTabUnderline.map { Rect($0, scale: scale) }
        outlinePanel = layout.outlinePanel.map { Rect($0, scale: scale) }
        outlinePanelIsOverlay = layout.outlinePanelIsOverlay
        stripDividerX = layout.macStrip.map { length($0.dividerX) }
    }
}

/// The reference file: one record per matrix cell, sorted by id so the file
/// diffs cleanly, with the shell that produced it named in the header.
public struct ChromeLayoutReference: Codable, Equatable, Sendable {
    /// "catalyst" or "appkit".
    public var shell: String
    /// ISO date of the capture.
    public var captured: String
    public var cells: [ChromeLayoutRecord]

    public init(shell: String, captured: String, cells: [ChromeLayoutRecord]) {
        self.shell = shell
        self.captured = captured
        self.cells = cells.sorted { $0.id < $1.id }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ChromeLayoutReference {
        try JSONDecoder().decode(ChromeLayoutReference.self, from: data)
    }

    public func cell(_ id: String) -> ChromeLayoutRecord? {
        cells.first { $0.id == id }
    }
}
