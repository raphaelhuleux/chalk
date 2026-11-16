import Foundation

/// Folding for the outline panel: which rows a folded heading hides, and a
/// key for each item that survives edits elsewhere in the document. Works on
/// `OutlinePalettePolicy.indentLevels`, so a callout under a heading folds
/// with it.
public enum OutlineFolding {
    /// True where the next item is nested deeper: the rows that get a chevron.
    public static func foldable(indents: [Int]) -> [Bool] {
        indents.indices.map { i in i + 1 < indents.count && indents[i + 1] > indents[i] }
    }

    /// Item indices left visible when the items at `folded` are collapsed:
    /// everything after a folded item up to the next item at or above its
    /// depth is hidden.
    public static func visibleIndices(indents: [Int], folded: Set<Int>) -> [Int] {
        var visible: [Int] = []
        var hideDeeperThan: Int?
        for (i, indent) in indents.enumerated() {
            if let depth = hideDeeperThan {
                if indent > depth { continue }
                hideDeeperThan = nil
            }
            visible.append(i)
            if folded.contains(i) { hideDeeperThan = indent }
        }
        return visible
    }

    /// The row that stands for `index`: the item itself when visible, else
    /// its folded ancestor (the last visible item before it).
    public static func row(for index: Int, visible: [Int]) -> Int? {
        var row: Int?
        for (r, i) in visible.enumerated() {
            if i > index { break }
            row = r
        }
        return row
    }

    /// `index` and every item nested under it.
    public static func subtree(of index: Int, indents: [Int]) -> [Int] {
        guard indents.indices.contains(index) else { return [] }
        var result = [index]
        var i = index + 1
        while i < indents.count, indents[i] > indents[index] {
            result.append(i)
            i += 1
        }
        return result
    }

    /// A fold key per item: kind, level and title, plus which repeat of that
    /// triple it is. Line numbers are left out so typing above a folded
    /// section keeps it folded.
    public static func keys(for items: [OutlineItem]) -> [String] {
        var seen: [String: Int] = [:]
        return items.map { item in
            let base = "\(item.kind.rawValue)|\(item.level)|\(item.title)"
            let n = seen[base, default: 0]
            seen[base] = n + 1
            return "\(base)#\(n)"
        }
    }
}
