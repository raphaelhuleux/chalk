import Foundation

/// Subsequence fuzzy matcher, fzf-style: every whitespace-separated term must
/// match as a case-insensitive subsequence, in any order. Scores only matter
/// for ordering.
public enum FuzzyMatcher {
    private static let boundary: Set<Character> = ["/", ".", "_", "-", " "]

    /// Both arguments already lowercased. nil if `q` is not a subsequence.
    static func scoreTerm(_ q: [Character], _ t: [Character]) -> Double? {
        var qi = 0
        var score = 0.0
        var prev = -2
        var first = -1

        var ti = 0
        while ti < t.count && qi < q.count {
            if t[ti] == q[qi] {
                if first < 0 { first = ti }
                score += (ti == prev + 1) ? 8 : 1            // consecutive bonus
                if ti == 0 || boundary.contains(t[ti - 1]) { // word-boundary bonus
                    score += 10
                }
                prev = ti
                qi += 1
            }
            ti += 1
        }

        if qi < q.count { return nil }   // not all term chars consumed
        score -= Double(first) * 0.5     // prefer terms that appear earlier
        return score
    }

    /// The query's lowercased, whitespace-separated terms; nil when blank.
    private static func terms(of query: String) -> [[Character]]? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return nil }
        return q.split(whereSeparator: { $0.isWhitespace }).map { Array($0) }
    }

    /// Summed score across terms, or nil if any term fails. Empty query
    /// scores 0.
    public static func score(query: String, target: String) -> Double? {
        guard let terms = terms(of: query) else { return 0 }
        return score(terms: terms, target: target)
    }

    /// `score(query:target:)` over a query already split by `terms(of:)`, so
    /// `filter` splits it once instead of per item.
    static func score(terms: [[Character]], target: String) -> Double? {
        let t = Array(target.lowercased())

        var total = 0.0
        for term in terms {
            guard let s = scoreTerm(term, t) else { return nil }
            total += s
        }
        total -= Double(t.count) * 0.05  // prefer shorter targets
        return total
    }

    /// Filter and rank `items`. Empty query returns the first `limit` items
    /// unchanged; ties keep input order.
    public static func filter<T>(
        query: String,
        items: [T],
        key: (T) -> String,
        limit: Int = 50
    ) -> [T] {
        guard let terms = terms(of: query) else {
            return Array(items.prefix(limit))
        }
        var scored: [(item: T, score: Double, index: Int)] = []
        for (i, item) in items.enumerated() {
            if let s = score(terms: terms, target: key(item)) {
                scored.append((item, s, i))
            }
        }
        scored.sort { a, b in
            a.score != b.score ? a.score > b.score : a.index < b.index
        }
        return scored.prefix(limit).map { $0.item }
    }
}
