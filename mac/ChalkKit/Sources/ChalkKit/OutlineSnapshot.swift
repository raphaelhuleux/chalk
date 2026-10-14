import Foundation

/// Swift mirror of editor-core's `OutlineItem` (editor/outline.ts). Not a
/// HostPort message: pulled over the `window.__chalkEditor` bridge or pushed
/// as transport-internal `outline` messages. Field names must match the TS
/// JSON; optional fields are absent on the wire, never null.
public struct OutlineItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case heading
        case callout
        case figure
        /// A beamer `\begin{frame}` — one slide of a deck.
        case frame
    }

    public let kind: Kind
    /// Heading depth 1…6; 0 for callouts, figures and frames.
    public let level: Int
    /// Display text; empty for a callout with no title.
    public let title: String
    /// 1-based line number, fed straight to `revealLine`.
    public let line: Int
    /// The environment type (`theorem`, `definition`, …); callouts only.
    public let calloutType: String?
    /// Callout per-type ordinal, figure ordinal, or slide number.
    public let number: Int?

    public init(kind: Kind, level: Int, title: String, line: Int,
                calloutType: String?, number: Int?) {
        self.kind = kind
        self.level = level
        self.title = title
        self.line = line
        self.calloutType = calloutType
        self.number = number
    }

    /// Row badge text; nil for headings. The callout label is the capitalized
    /// type, so there is no label map to drift from editor-core's.
    public var badge: String? {
        switch kind {
        case .heading:
            return nil
        case .callout:
            guard let type = calloutType else { return nil }
            let label = type.prefix(1).uppercased() + type.dropFirst()
            return number.map { "\(label) \($0)" } ?? label
        case .figure:
            return number.map { "Fig. \($0)" } ?? "Fig."
        case .frame:
            return number.map { "Slide \($0)" } ?? "Slide"
        }
    }
}

/// Prose counts for the outline panel's footer (editor-core `DocumentStats`).
public struct DocumentStats: Codable, Equatable, Sendable {
    public let words: Int
    /// Prose characters, spaces excluded.
    public let characters: Int
    /// Words inside a non-empty selection, else nil.
    public let selectionWords: Int?

    public init(words: Int, characters: Int, selectionWords: Int? = nil) {
        self.words = words
        self.characters = characters
        self.selectionWords = selectionWords
    }
}

/// Outline plus cursor line in one payload, so the palette can pre-select
/// the current section without a second bridge round trip. `stats` is nil
/// before the editor has a document.
public struct OutlineSnapshot: Codable, Equatable, Sendable {
    public let items: [OutlineItem]
    public let cursorLine: Int
    public let stats: DocumentStats?

    public init(items: [OutlineItem], cursorLine: Int, stats: DocumentStats? = nil) {
        self.items = items
        self.cursorLine = cursorLine
        self.stats = stats
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case cursorLine
        case stats
    }

    /// Drops items of unknown kind (a newer editor bundle) instead of failing
    /// the whole snapshot, which callers' `try?` would turn into a blank
    /// outline. A missing kind or malformed known-kind item still throws.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursorLine = try container.decode(Int.self, forKey: .cursorLine)
        items = try container.decode([LenientOutlineItem].self, forKey: .items)
            .compactMap(\.item)
        // Optional, and a malformed one only costs the footer, not the outline.
        stats = try? container.decodeIfPresent(DocumentStats.self, forKey: .stats)
    }

    public static let empty = OutlineSnapshot(items: [], cursorLine: 1)
}

/// Decode shim for `OutlineSnapshot.items`: unknown `kind` yields nil.
private struct LenientOutlineItem: Decodable {
    let item: OutlineItem?

    private enum ProbeKeys: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: ProbeKeys.self)
        let rawKind = try probe.decode(String.self, forKey: .kind)
        guard OutlineItem.Kind(rawValue: rawKind) != nil else {
            item = nil
            return
        }
        item = try OutlineItem(from: decoder)
    }
}
