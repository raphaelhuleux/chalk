import Foundation

/// A user-defined LaTeX shortcut, created in Settings → LaTeX Shortcuts.
/// Serialized to hsnips text by `SnippetComposer` and appended after the
/// bundled defaults, at a higher priority so it wins trigger conflicts.
public struct UserSnippet: Codable, Equatable {
    public let id: String
    public var trigger: String
    public var replacement: String
    public var options: SnippetOptions
    public var enabled: Bool
    /// For a fork, the built-in's disable key. The composer disables that
    /// built-in so the override holds even if the fork changes the trigger.
    public var overridesBuiltinKey: String?

    public init(
        id: String = UUID().uuidString,
        trigger: String,
        replacement: String,
        options: SnippetOptions = SnippetOptions(),
        enabled: Bool = true,
        overridesBuiltinKey: String? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.replacement = replacement
        self.options = options
        self.enabled = enabled
        self.overridesBuiltinKey = overridesBuiltinKey
    }

    private enum CodingKeys: String, CodingKey {
        case id, trigger, replacement, options, enabled, overridesBuiltinKey
        // Pre-options records carried these two instead of `options`.
        case autoExpand, mathOnly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        trigger = try container.decode(String.self, forKey: .trigger)
        replacement = try container.decode(String.self, forKey: .replacement)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        overridesBuiltinKey = try container.decodeIfPresent(
            String.self, forKey: .overridesBuiltinKey)

        if let stored = try container.decodeIfPresent(SnippetOptions.self, forKey: .options) {
            options = stored
        } else {
            // `mathOnly: false` meant "anywhere", not "prose only".
            let autoExpand = try container.decodeIfPresent(Bool.self, forKey: .autoExpand) ?? true
            let mathOnly = try container.decodeIfPresent(Bool.self, forKey: .mathOnly) ?? true
            options = SnippetOptions(mode: mathOnly ? .math : .any, autoExpand: autoExpand)
        }
    }

    /// `autoExpand` and `mathOnly` are still written so an older build,
    /// whose decoder requires them, can read the record; omitting them would
    /// erase every user shortcut on a rollback.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(replacement, forKey: .replacement)
        try container.encode(options, forKey: .options)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(overridesBuiltinKey, forKey: .overridesBuiltinKey)
        try container.encode(options.autoExpand, forKey: .autoExpand)
        try container.encode(options.mode == .math, forKey: .mathOnly)
    }
}

/// Persists user snippets and the set of disabled built-in snippets.
///
/// Every mutation rewrites the whole blob, so an unreadable record must never
/// read as "no records". Such records ride along verbatim
/// (`StoredRecord.unreadable`); a blob that isn't a JSON array reads as empty
/// but is never overwritten.
public final class UserSnippetStore {
    /// One element of the stored array. `unreadable` preserves a record this
    /// build cannot decode.
    private enum StoredRecord: Codable {
        case snippet(UserSnippet)
        case unreadable(JSONValue)

        init(from decoder: Decoder) throws {
            if let snippet = try? UserSnippet(from: decoder) {
                self = .snippet(snippet)
            } else {
                self = .unreadable(try JSONValue(from: decoder))
            }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .snippet(let snippet): try snippet.encode(to: encoder)
            case .unreadable(let value): try value.encode(to: encoder)
            }
        }

        var snippet: UserSnippet? {
            if case .snippet(let snippet) = self { return snippet }
            return nil
        }
    }

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "chalk.userSnippets") {
        self.defaults = defaults
        self.key = key
    }

    /// `[]` when nothing is stored; nil when data exists but isn't a readable
    /// JSON array. Mutations treat nil as "hands off".
    private func loadRecords() -> [StoredRecord]? {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try? JSONDecoder().decode([StoredRecord].self, from: data)
    }

    public func snippets() -> [UserSnippet] {
        (loadRecords() ?? []).compactMap(\.snippet)
    }

    private func save(_ records: [StoredRecord]) {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key)
        }
    }

    /// Insert or (matching on `id`) replace a snippet, preserving list order.
    /// A no-op while the stored blob is unreadable.
    @discardableResult
    public func upsert(_ snippet: UserSnippet) -> UserSnippet {
        guard var records = loadRecords() else { return snippet }
        if let index = records.firstIndex(where: { $0.snippet?.id == snippet.id }) {
            records[index] = .snippet(snippet)
        } else {
            records.append(.snippet(snippet))
        }
        save(records)
        return snippet
    }

    public func remove(id: String) {
        guard let records = loadRecords() else { return }
        save(records.filter { $0.snippet?.id != id })
    }

    /// Disabled built-ins, keyed as `# chalk-disable:` keys them (plain
    /// trigger or raw regex source).
    public func disabledBuiltinKeys() -> Set<String> {
        Set(defaults.stringArray(forKey: key + ".disabledBuiltins") ?? [])
    }

    public func setBuiltinDisabled(key builtinKey: String, disabled: Bool) {
        var keys = disabledBuiltinKeys()
        if disabled { keys.insert(builtinKey) } else { keys.remove(builtinKey) }
        defaults.set(keys.sorted(), forKey: key + ".disabledBuiltins")
    }
}
