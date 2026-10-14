import Foundation

/// One row of the Settings shortcuts rail: a group of the `.hsnips` file's
/// `# Title` banners. Not a fixed enum, so a banner the table does not name
/// still gets its own row instead of dropping off screen.
public struct ShortcutCategory: Equatable, Hashable {
    /// Persisted as the selected row, so it must not change with the title.
    public let id: String
    public let title: String
    /// SF Symbol for the rail.
    public let symbol: String
    /// `.hsnips` banners this row draws from. Empty for `yours` (user store).
    public let sections: [String]

    public init(id: String, title: String, symbol: String, sections: [String]) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.sections = sections
    }

    /// True when this row shows `builtin`.
    public func contains(_ builtin: BuiltinSnippet) -> Bool {
        sections.contains(builtin.section)
    }
}

extension ShortcutCategory {
    /// The user's own shortcuts, and the only row that offers the add row.
    public static let yours = ShortcutCategory(
        id: "yours", title: "Your Shortcuts", symbol: "star", sections: [])

    /// Built-in groups, in rail order.
    public static let curated: [ShortcutCategory] = [
        ShortcutCategory(id: "greek", title: "Greek letters", symbol: "textformat",
                         sections: ["Greek alphabet"]),
        ShortcutCategory(id: "symbols", title: "Symbols", symbol: "number",
                         sections: ["Symbols"]),
        ShortcutCategory(id: "operations", title: "Operations", symbol: "plusminus",
                         sections: ["Operations", "Fraction"]),
        ShortcutCategory(id: "calculus", title: "Calculus", symbol: "function",
                         sections: ["Derivatives", "Integrals"]),
        ShortcutCategory(id: "linear-algebra", title: "Linear algebra", symbol: "squareshape.split.2x2",
                         sections: ["Linear algebra"]),
        ShortcutCategory(id: "physics", title: "Physics", symbol: "atom",
                         sections: ["Physics", "Unit vectors"]),
        ShortcutCategory(id: "environments", title: "Environments", symbol: "curlybraces",
                         sections: ["Environments", "LaTeX environments (no math context required)"]),
        ShortcutCategory(id: "delimiters", title: "Delimiters", symbol: "parentheses",
                         sections: ["Brackets", "Math mode"]),
    ]

    /// The rail: `yours`, curated groups that have snippets, then a row per
    /// unclaimed banner in first-appearance order.
    public static func all(for builtins: [BuiltinSnippet]) -> [ShortcutCategory] {
        let present = Set(builtins.map(\.section))
        var rail: [ShortcutCategory] = [.yours]
        rail += curated.filter { category in
            category.sections.contains(where: present.contains)
        }

        let claimed = Set(curated.flatMap(\.sections))
        var seen = Set<String>()
        for builtin in builtins where !claimed.contains(builtin.section) {
            guard !builtin.section.isEmpty, seen.insert(builtin.section).inserted else { continue }
            rail.append(ShortcutCategory(
                id: "section:" + builtin.section,
                title: builtin.section,
                symbol: "questionmark.folder",
                sections: [builtin.section]))
        }
        return rail
    }
}
