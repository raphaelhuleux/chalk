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

    /// Where a tab dragged in from another group's strip lands: before the first item whose
    /// midpoint (`midXs`, laid-out order) is past `probeX`, else at the end.
    public static func insertionIndex(probeX: CGFloat, midXs: [CGFloat]) -> Int {
        midXs.firstIndex { probeX < $0 } ?? midXs.count
    }
}

/// Where a tab's close × sits between its own name and the next one, from the row's spacing
/// tokens and the glyph's measured ink width. The × must read as its own tab's: a slot widened
/// without the gap once put it nearer the next name than its own
/// (docs/issues/2026-11-16-tab-row-regressions.md).
public struct TabCloseSpacing: Equatable, Sendable {
    /// Inside each item, both sides.
    public var labelPadding: CGFloat
    /// Label → slot.
    public var innerGap: CGFloat
    public var slotWidth: CGFloat
    /// Between items.
    public var tabGap: CGFloat
    /// The × glyph's drawn width, centred in the slot.
    public var glyphInkWidth: CGFloat

    public init(labelPadding: CGFloat, innerGap: CGFloat, slotWidth: CGFloat,
                tabGap: CGFloat, glyphInkWidth: CGFloat) {
        self.labelPadding = labelPadding
        self.innerGap = innerGap
        self.slotWidth = slotWidth
        self.tabGap = tabGap
        self.glyphInkWidth = glyphInkWidth
    }

    /// The × may sit at most half as far from its own name as from the next one.
    public static let minimumSeparationRatio: CGFloat = 2
    /// And never nearer the next name than this.
    public static let minimumNextGap: CGFloat = 10

    /// Own label's end → the ×'s ink.
    public var ownGap: CGFloat { innerGap + (slotWidth - glyphInkWidth) / 2 }

    /// The ×'s ink → the next label, for a slot inside the item (active or unsaved tab) or one
    /// hanging past it into the gap (a clean background tab's hover ×).
    public func nextGap(reserved: Bool) -> CGFloat {
        let inkToSlotEnd = (slotWidth - glyphInkWidth) / 2
        let slotEndToNextLabel = reserved
            ? 2 * labelPadding + tabGap
            : labelPadding + tabGap + labelPadding - (innerGap + slotWidth)
        return inkToSlotEnd + slotEndToNextLabel
    }

    /// How far a hanging slot reaches past the gap into the next item (positive is a defect: the
    /// slot's hit area would cover the next tab).
    public var hangingOverrun: CGFloat { innerGap - labelPadding + slotWidth - tabGap }

    /// The rules this spacing breaks, by name; empty when it is sound.
    public var violations: [String] {
        var broken: [String] = []
        for reserved in [true, false] {
            let next = nextGap(reserved: reserved)
            let kind = reserved ? "reserved" : "hanging"
            if next < Self.minimumSeparationRatio * ownGap {
                broken.append("\(kind): × is \(ownGap)pt from its name but \(next)pt from the next")
            }
            if next < Self.minimumNextGap {
                broken.append("\(kind): × is only \(next)pt from the next name")
            }
        }
        if hangingOverrun > 0 {
            broken.append("hanging slot reaches \(hangingOverrun)pt into the next tab")
        }
        return broken
    }
}
