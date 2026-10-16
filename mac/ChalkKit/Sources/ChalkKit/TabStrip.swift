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
