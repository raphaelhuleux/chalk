import CoreGraphics
import Foundation

/// The tab name row's shared rules and numbers: what a row shows
/// (`TabStripPolicy`), the motion tokens (`ChromeMotion`) and the spec metrics
/// (`TabStripMetrics`). Pure Foundation/CoreGraphics; the row's colours are the
/// theme's (`ThemePalette.tab*`, ChalkTheme.swift).
/// Pure rules for the tab name row's anatomy.
public enum TabStripPolicy {
    /// What occupies a tab's trailing slot. A dirty tab shows the dot, a clean
    /// one the close ×. Never both — closing an unsaved tab goes through the
    /// dot's hover swap, ⌘W, or the context menu.
    public enum SlotContent: Equatable, Sendable {
        case dot
        case close
    }

    public static func slotContent(isDirty: Bool) -> SlotContent {
        isDirty ? .dot : .close
    }

    /// Whether the slot takes LAYOUT space inside the item.
    ///
    /// Reserved when something rests in it (active tab, unsaved dot). A clean
    /// background tab's hover × hangs in the following gap at the same offset,
    /// so revealing it never reflows the row.
    public static func slotIsReserved(isActive: Bool, isDirty: Bool) -> Bool {
        isActive || isDirty
    }

    /// Whether a tab's filename run takes the synthetic slant.
    ///
    /// Only the ACTIVE preview slants: `isPreview` is true of every
    /// uncommitted tab, but `open(url:reuseCurrentIfClean:)` only reuses the
    /// active one, so that is the only tab a sidebar click will replace.
    public static func isOblique(isActive: Bool, isPreview: Bool) -> Bool {
        isActive && isPreview
    }

    /// The immediate parent folder name for the label's dim prefix
    /// ("test-docs" for …/test-docs/least-squares.md; rendering appends "/").
    /// Nil when there is no meaningful parent (drafts have no URL at all;
    /// files at a volume root have no folder worth naming).
    public static func folderPrefix(for url: URL) -> String? {
        let parent = url.deletingLastPathComponent().lastPathComponent
        switch parent {
        case "", "/", ".", "..": return nil
        default: return parent
        }
    }

    /// Which tabs actually need that prefix: the ones whose filename is open
    /// more than once.
    ///
    /// Computed over the whole open set. Returns one flag per input, in order.
    public static func needsFolderPrefix(names: [String]) -> [Bool] {
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        return names.map { (counts[$0] ?? 0) > 1 }
    }

    /// A tab's row in the overflow menu: the full "folder/name" label, so two
    /// tabs sharing a filename stay distinguishable there too.
    public static func menuTitle(name: String, folder: String?) -> String {
        (folder.map { "\($0)/" } ?? "") + name
    }

    /// Whether the underline slides to the active name rather than being
    /// placed: only a change of active tab, from an underline already on
    /// screen, moves (docs/motion.md "Tab switch"). Each host adds its own
    /// Reduce Motion gate.
    public static func underlineSlides<ID: Equatable>(
        wasHidden: Bool, previousID: ID?, newID: ID
    ) -> Bool {
        !wasHidden && previousID != nil && previousID != newID
    }

    /// One drag-reorder step: the slot the dragged item at `index` moves to
    /// when its probe sits at `probeX`, or nil to stay. It passes a
    /// neighbour once the probe crosses that neighbour's midpoint
    /// (`midXs[i]`, the arranged items' laid-out midpoints, `index`
    /// included); the left neighbour is checked first. Callers loop until
    /// nil so a fast drag can cross several items in one event.
    public static func reorderStep(index: Int, probeX: CGFloat, midXs: [CGFloat]) -> Int? {
        if index > 0, probeX < midXs[index - 1] { return index - 1 }
        if index < midXs.count - 1, probeX > midXs[index + 1] { return index + 1 }
        return nil
    }
}

/// Chrome animation clocks both toolkits run on (docs/motion.md, Tokens), so
/// the AppKit strip and the UIKit chrome cannot drift apart.
public enum ChromeMotion {
    /// Tab close, cover fades, the tab-switch cross-fade and the underline
    /// slide (`ChalkMetrics.motionFast` on the UIKit side).
    public static let fast: TimeInterval = 0.15
    /// The auto-hide slide and fade, and the glue's default for an untagged
    /// `setFaded` post.
    public static let autoHide: TimeInterval = 0.22
}

/// The tab row's spacing and size tokens, in MAC points (spec px at 1×).
///
/// The AppKit strip uses these raw (the titlebar escapes the 0.77× Catalyst
/// scale); the UIKit strip wraps each in `ChalkMetrics.s()` to land the same
/// physical size.
public enum TabStripMetrics {
    /// The name row's own height.
    public static let stripHeight: CGFloat = 46
    /// Between name items.
    public static let gap: CGFloat = 12
    /// Inside each item, both sides.
    public static let labelPadding: CGFloat = 8
    /// Label → trailing slot.
    public static let innerGap: CGFloat = 8
    /// Label truncation cap.
    public static let maxTabWidth: CGFloat = 290
    /// The active name's accent underline.
    public static let underlineHeight: CGFloat = 2
    /// …and its distance below the label.
    public static let underlineGap: CGFloat = 7
    /// Unsaved dot.
    public static let dotSize: CGFloat = 5
    /// The trailing slot that holds the dot or the close ×.
    public static let slotWidth: CGFloat = 14
    /// The trailing "+" button's box…
    public static let newTabSize = CGSize(width: 28, height: 34)
    /// …and the ink inside it (NewTabGlyphSizeTests measures the ink).
    public static let newTabGlyph: CGFloat = 10
    /// The overflow chevron's symbol point size.
    public static let overflowGlyph: CGFloat = 10
    /// The close ×'s symbol point size, inside the trailing slot.
    public static let closeGlyph: CGFloat = 7.5
    /// Mono name size (spec value).
    public static let fontSize: CGFloat = 12
    /// Divider → first item edge; with the item's 8pt padding the first label
    /// lands 22pt past the divider.
    public static let dividerGap: CGFloat = 14

    /// tan(12°): the preview tab's synthetic slant (no italic face is
    /// bundled). Not a length: never pass this through `s()`.
    public static let obliqueSlant: CGFloat = 0.2126

    // Placement inside the NSToolbar (see layoutInTitlebar). The UIKit band
    // reuses the first two for its trailing padding and its full-screen
    // leading edge (`ChalkMetrics.headerPadding`, `tabStripLeading`).

    /// Gap kept clear at the titlebar's trailing edge.
    public static let trailingMargin: CGFloat = 14
    /// Gap between the traffic lights and the first name.
    public static let trafficLightGap: CGFloat = 16
    /// Leading edge used only before the window's buttons can be measured.
    /// AppKit only.
    public static let fallbackLeading: CGFloat = 91
}
