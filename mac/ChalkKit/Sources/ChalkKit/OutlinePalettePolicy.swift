import Foundation

/// Pure decisions behind the outline palette, kept out of the view controller
/// so they are unit-testable.
public enum OutlinePalettePolicy {
    /// Row to highlight on open: the last item at or before the cursor's line,
    /// else the first row.
    public static func preselectedIndex(items: [OutlineItem], cursorLine: Int) -> Int {
        var index = 0
        for (i, item) in items.enumerated() where item.line <= cursorLine {
            index = i
        }
        return index
    }

    /// Fuzzy-match key. Non-headings prepend kind and number ("Figure" spelled
    /// out, unlike the badge) so a query like "theo" filters by kind.
    public static func searchKey(_ item: OutlineItem) -> String {
        switch item.kind {
        case .heading:
            return item.title
        case .callout:
            let badge = item.badge ?? ""
            return item.title.isEmpty ? badge : "\(badge) \(item.title)"
        case .figure:
            let label = item.number.map { "Figure \($0)" } ?? "Figure"
            return item.title.isEmpty ? label : "\(label) \(item.title)"
        case .frame:
            let label = item.badge ?? "Slide"
            return item.title.isEmpty ? label : "\(label) \(item.title)"
        }
    }

    /// Empty query keeps document order.
    public static func filter(query: String, items: [OutlineItem], limit: Int = 50) -> [OutlineItem] {
        FuzzyMatcher.filter(query: query, items: items, key: searchKey, limit: limit)
    }

    /// Per-row indent steps for the unfiltered list. Heading levels are
    /// relative to the document's minimum (a .tex `\section` is level 3);
    /// other items sit one step under the preceding heading.
    public static func indentLevels(for items: [OutlineItem]) -> [Int] {
        let headingLevels = items.filter { $0.kind == .heading }.map(\.level)
        let minLevel = headingLevels.min() ?? 1

        var current = -1 // preceding heading's normalized indent; -1 = none yet
        return items.map { item in
            if item.kind == .heading {
                let indent = max(0, item.level - minLevel)
                current = indent
                return indent
            }
            return current + 1
        }
    }
}
