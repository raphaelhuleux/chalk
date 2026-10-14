import Foundation

/// The behavior switches on one shortcut, compiled to hsnips flags plus a
/// `context` line by `SnippetComposer`.
public struct SnippetOptions: Codable, Equatable {
    /// Where the shortcut may fire. `.any` emits no `context` line at all.
    public enum Mode: String, Codable {
        case math
        case text
        case any
    }

    public var mode: Mode
    /// hsnips `A`: expand while typing instead of waiting for Tab.
    public var autoExpand: Bool
    /// hsnips `w`: only fire when the trigger stands alone. Replaces the
    /// default `i` rather than joining it.
    public var wholeWord: Bool
    /// hsnips `b`: only fire at the start of a line.
    public var lineStart: Bool
    /// Trigger is a regex; the composer emits it backtick-quoted.
    public var isRegex: Bool

    public init(
        mode: Mode = .math,
        autoExpand: Bool = true,
        wholeWord: Bool = false,
        lineStart: Bool = false,
        isRegex: Bool = false
    ) {
        self.mode = mode
        self.autoExpand = autoExpand
        self.wholeWord = wholeWord
        self.lineStart = lineStart
        self.isRegex = isRegex
    }

    private enum CodingKeys: String, CodingKey {
        case mode, autoExpand, wholeWord, lineStart, isRegex
    }

    /// Tolerant by hand: a record from another build's schema must degrade,
    /// not throw, or one bad element can cost the whole `UserSnippetStore`
    /// array. Unknown mode and missing keys take the initializer defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawMode = try container.decodeIfPresent(String.self, forKey: .mode)
        mode = rawMode.flatMap(Mode.init(rawValue:)) ?? .math
        autoExpand = try container.decodeIfPresent(Bool.self, forKey: .autoExpand) ?? true
        wholeWord = try container.decodeIfPresent(Bool.self, forKey: .wholeWord) ?? false
        lineStart = try container.decodeIfPresent(Bool.self, forKey: .lineStart) ?? false
        isRegex = try container.decodeIfPresent(Bool.self, forKey: .isRegex) ?? false
    }

    /// The flag group for the snippet header, in a stable order.
    public var flagString: String {
        var flags = ""
        if autoExpand { flags += "A" }
        flags += wholeWord ? "w" : "i"
        if lineStart { flags += "b" }
        return flags
    }

    /// The `context` line body, or nil when the shortcut fires anywhere.
    public var contextFilter: String? {
        switch mode {
        case .math: return "math(context)"
        case .text: return "!math(context)"
        case .any: return nil
        }
    }

    /// Whether the Whole word control does anything on this shortcut. False
    /// for regex triggers: editor-core's `findMatch` ignores `w` on them.
    /// Display only; the stored flag and emitted `w` are left alone.
    public var wholeWordApplies: Bool { !isRegex }

    /// Chips shown in the Options column, in display order.
    public var chipLabels: [String] {
        var labels: [String] = []
        if isRegex { labels.append("Regex") }
        switch mode {
        case .math: labels.append("Math")
        case .text: labels.append("Text")
        case .any: break
        }
        if autoExpand { labels.append("Auto") }
        if wholeWord && wholeWordApplies { labels.append("Whole word") }
        if lineStart { labels.append("Line start") }
        return labels
    }
}
