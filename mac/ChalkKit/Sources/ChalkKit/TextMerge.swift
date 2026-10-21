import Foundation

/// Line-based three-way merge for an external write (an AI agent, another editor) that lands while
/// the buffer holds unsaved edits.
///
/// Conservative: changes from the two sides must be separated by at least one untouched line, or be
/// identical. Anything closer returns nil, and the caller keeps its own text so the save-time
/// conflict copy takes over. A wrong merge would be written back silently; a refused one is not.
public enum TextMerge {
    public static func threeWay(base: String, mine: String, theirs: String) -> String? {
        if mine == theirs || theirs == base { return mine }
        if mine == base { return theirs }

        let baseLines = lines(base)
        let mineHunks = hunks(from: baseLines, to: lines(mine))
        let theirHunks = hunks(from: baseLines, to: lines(theirs))

        let all = (mineHunks.map { ($0, true) } + theirHunks.map { ($0, false) })
            .sorted { ($0.0.base.lowerBound, $0.0.base.upperBound) < ($1.0.base.lowerBound, $1.0.base.upperBound) }

        var out: [Substring] = []
        var cursor = 0
        var index = 0
        while index < all.count {
            // A cluster: hunks whose base ranges overlap or touch. Hunks of one side never touch
            // each other (a kept line separates them), so a cluster spanning both sides is a clash.
            let lower = all[index].0.base.lowerBound
            var upper = all[index].0.base.upperBound
            var cluster = [all[index]]
            index += 1
            while index < all.count, all[index].0.base.lowerBound <= upper {
                upper = max(upper, all[index].0.base.upperBound)
                cluster.append(all[index])
                index += 1
            }
            out += baseLines[cursor..<lower]
            let fromMine = cluster.filter(\.1).map(\.0)
            let fromTheirs = cluster.filter { !$0.1 }.map(\.0)
            let mineSpan = apply(fromMine, to: baseLines, in: lower..<upper)
            if !fromMine.isEmpty, !fromTheirs.isEmpty,
               mineSpan != apply(fromTheirs, to: baseLines, in: lower..<upper) {
                return nil
            }
            out += fromMine.isEmpty ? apply(fromTheirs, to: baseLines, in: lower..<upper) : mineSpan
            cursor = upper
        }
        out += baseLines[cursor...]
        return out.joined()
    }

    /// Lines with their terminators, so joining reproduces the bytes. "\r\n" is one `Character`,
    /// so it needs its own match.
    static func lines(_ text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index] == "\n" || text[index] == "\r\n" {
                result.append(text[start..<next])
                start = next
            }
            index = next
        }
        if start < text.endIndex { result.append(text[start...]) }
        return result
    }

    /// `base[base]` is replaced by `lines`.
    struct Hunk {
        let base: Range<Int>
        let lines: [Substring]
    }

    /// The changed regions of `other` against `base`. Common head and tail lines are trimmed before
    /// the diff, so a localized edit in a long file costs little.
    static func hunks(from base: [Substring], to other: [Substring]) -> [Hunk] {
        var head = 0
        while head < base.count, head < other.count, base[head] == other[head] { head += 1 }
        var tail = 0
        while tail < base.count - head, tail < other.count - head,
              base[base.count - 1 - tail] == other[other.count - 1 - tail] { tail += 1 }
        let baseMid = Array(base[head..<(base.count - tail)])
        let otherMid = Array(other[head..<(other.count - tail)])

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in otherMid.difference(from: baseMid) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        // Kept lines pair up in order; each run of removals and insertions between them is a hunk.
        var result: [Hunk] = []
        var i = 0
        var j = 0
        while i < baseMid.count || j < otherMid.count {
            if i < baseMid.count, j < otherMid.count, !removed.contains(i), !inserted.contains(j) {
                i += 1
                j += 1
                continue
            }
            let start = i
            let otherStart = j
            while i < baseMid.count, removed.contains(i) { i += 1 }
            while j < otherMid.count, inserted.contains(j) { j += 1 }
            result.append(Hunk(base: (head + start)..<(head + i), lines: Array(otherMid[otherStart..<j])))
        }
        return result
    }

    /// `base[range]` with one side's `hunks` (sorted, all inside `range`) applied.
    private static func apply(_ hunks: [Hunk], to base: [Substring], in range: Range<Int>) -> [Substring] {
        var out: [Substring] = []
        var cursor = range.lowerBound
        for hunk in hunks {
            out += base[cursor..<hunk.base.lowerBound]
            out += hunk.lines
            cursor = hunk.base.upperBound
        }
        out += base[cursor..<range.upperBound]
        return out
    }
}
