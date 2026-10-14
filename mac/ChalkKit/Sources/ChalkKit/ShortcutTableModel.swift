import Foundation

/// Which row of the shortcuts table a callback is about, independent of where
/// that row currently sits. Not an `IndexPath`: cell reuse, a `reloadData()`
/// under an open menu, or the resign in `prepareForReuse()` invalidate it and
/// cause wrong-row writes.
public enum ShortcutRowIdentity: Hashable {
    /// A shortcut the user wrote, keyed by its stored id.
    case user(String)
    /// A built-in, keyed by its disable key. A fork keeps this identity, so a
    /// callback issued before the fork still resolves after it.
    case builtin(String)
    /// The single trailing blank row that creates a new shortcut.
    case addRow
}

/// One row of the Settings shortcuts table, whatever it came from.
public struct ShortcutRow: Equatable {
    public enum Source: Equatable {
        /// A shortcut the user wrote.
        case user(UserSnippet)
        /// A built-in as shipped.
        case builtin(BuiltinSnippet)
        /// A built-in the user edited: renders the fork, resets to the built-in.
        case fork(BuiltinSnippet, UserSnippet)
    }

    public let source: Source
    public let trigger: String
    public let replacement: String
    public let options: SnippetOptions
    public let isEnabled: Bool
    /// True for a forked built-in — the row offers Reset.
    public let isModified: Bool

    /// The stored snippet behind this row, if any.
    public var userSnippet: UserSnippet? {
        switch source {
        case .user(let snippet): return snippet
        case .fork(_, let snippet): return snippet
        case .builtin: return nil
        }
    }

    /// Stable across a fork.
    public var identity: ShortcutRowIdentity {
        switch source {
        case .user(let snippet): return .user(snippet.id)
        case .builtin(let builtin): return .builtin(builtin.key)
        case .fork(let builtin, _): return .builtin(builtin.key)
        }
    }
}

/// Merges the user's shortcuts over the bundled built-ins into the two
/// sections the table renders.
public enum ShortcutTableModel {
    /// - Parameter category: the selected rail row, `nil` for everything. A
    ///   non-empty `query` ignores it: search is global.
    public static func rows(
        user: [UserSnippet],
        builtins: [BuiltinSnippet],
        disabledBuiltinKeys: Set<String>,
        query: String,
        category: ShortcutCategory? = nil
    ) -> (yours: [ShortcutRow], builtin: [ShortcutRow]) {
        let builtinKeys = Set(builtins.map(\.key))
        var forksByKey: [String: UserSnippet] = [:]
        var own: [UserSnippet] = []

        for snippet in user {
            // A fork whose built-in vanished from a newer bundled file is
            // just an ordinary shortcut.
            guard let key = snippet.overridesBuiltinKey, builtinKeys.contains(key) else {
                own.append(snippet)
                continue
            }
            // Two forks of one built-in (a corrupt or synced store): the later
            // wins the built-in row, the earlier surfaces as an ordinary one.
            if let displaced = forksByKey[key] {
                own.append(displaced)
            }
            forksByKey[key] = snippet
        }

        let yours = own.map { snippet in
            ShortcutRow(
                source: .user(snippet),
                trigger: snippet.trigger,
                replacement: snippet.replacement,
                options: snippet.options,
                isEnabled: snippet.enabled,
                isModified: false
            )
        }

        let builtinRows = builtins.map { builtin -> ShortcutRow in
            guard let fork = forksByKey[builtin.key] else {
                return ShortcutRow(
                    source: .builtin(builtin),
                    trigger: builtin.display,
                    replacement: builtin.replacement,
                    options: builtin.options,
                    isEnabled: !disabledBuiltinKeys.contains(builtin.key),
                    isModified: false
                )
            }
            return ShortcutRow(
                source: .fork(builtin, fork),
                trigger: fork.trigger,
                replacement: fork.replacement,
                options: fork.options,
                isEnabled: fork.enabled,
                isModified: true
            )
        }

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            guard let category else { return (yours, builtinRows) }
            if category == .yours { return (yours, []) }
            return ([], builtinRows.filter { row in
                switch row.source {
                case .builtin(let b), .fork(let b, _): return category.contains(b)
                case .user: return false
                }
            })
        }
        let needle = trimmed.lowercased()
        func matches(_ row: ShortcutRow) -> Bool {
            if row.trigger.lowercased().contains(needle) { return true }
            if row.replacement.lowercased().contains(needle) { return true }
            if case .builtin(let builtin) = row.source {
                return builtin.description.lowercased().contains(needle)
            }
            if case .fork(let builtin, _) = row.source {
                return builtin.description.lowercased().contains(needle)
            }
            return false
        }
        return (yours.filter(matches), builtinRows.filter(matches))
    }

    /// The row a callback names, searched over both sections. `nil` for the
    /// add row, and for a row that has since been deleted.
    public static func row(
        _ identity: ShortcutRowIdentity,
        yours: [ShortcutRow],
        builtin: [ShortcutRow]
    ) -> ShortcutRow? {
        yours.first { $0.identity == identity } ?? builtin.first { $0.identity == identity }
    }

    /// A user snippet seeded from a built-in, ready to edit in place.
    public static func fork(_ builtin: BuiltinSnippet) -> UserSnippet {
        UserSnippet(
            trigger: builtin.display,
            replacement: builtin.replacement,
            options: builtin.options,
            enabled: true,
            overridesBuiltinKey: builtin.key
        )
    }
}
