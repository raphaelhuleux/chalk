import Foundation

/// Swift mirror of the frozen `HostPort` protocol
/// (packages/editor-core/src/host-port.ts, carried by web/src/native-host.ts).
/// Must change together with both; the JSON shapes must match exactly.
/// Also the vocabulary of the `EditorSurface` seam.

// MARK: - Language

public enum EditorLanguage: String, Codable, Sendable, Equatable {
    case tex
    case md
}

// MARK: - Theme

/// Mirrors `ThemeColors`. TS `null` and absent both become `nil` (no
/// override); the editor treats them alike.
// Sent by the VS Code host only; the native shell themes via
// chalk-theme.css + data-theme.
public struct ThemeColors: Codable, Sendable, Equatable {
    public var keyword: String?
    public var tagName: String?
    public var comment: String?
    public var number: String?
    public var atom: String?
    public var bracket: String?
    public var specialVariable: String?
    public var invalid: String?

    public init(
        keyword: String? = nil,
        tagName: String? = nil,
        comment: String? = nil,
        number: String? = nil,
        atom: String? = nil,
        bracket: String? = nil,
        specialVariable: String? = nil,
        invalid: String? = nil
    ) {
        self.keyword = keyword
        self.tagName = tagName
        self.comment = comment
        self.number = number
        self.atom = atom
        self.bracket = bracket
        self.specialVariable = specialVariable
        self.invalid = invalid
    }
}

/// Mirrors `HeadingColors`: JSON keys are the strings "1".."6".
public struct HeadingColors: Codable, Sendable, Equatable {
    public var h1: String?
    public var h2: String?
    public var h3: String?
    public var h4: String?
    public var h5: String?
    public var h6: String?

    public init(
        h1: String? = nil,
        h2: String? = nil,
        h3: String? = nil,
        h4: String? = nil,
        h5: String? = nil,
        h6: String? = nil
    ) {
        self.h1 = h1
        self.h2 = h2
        self.h3 = h3
        self.h4 = h4
        self.h5 = h5
        self.h6 = h6
    }

    private enum CodingKeys: String, CodingKey {
        case h1 = "1", h2 = "2", h3 = "3", h4 = "4", h5 = "5", h6 = "6"
    }
}

// MARK: - Messages

/// Host → editor (the 6 inbound message types).
public enum HostToEditorMessage: Codable, Sendable, Equatable {
    /// `init`. `editorConfig` is passed through opaque. `epoch` is the host's
    /// text-push generation, echoed on every `edit` so the host can drop edits
    /// that predate a buffer swap (else a keystroke racing a reload lands the
    /// old text in the new file). Optional: the VS Code host doesn't send it.
    case initialize(text: String, language: EditorLanguage, editorConfig: JSONValue?, epoch: Int?)
    case update(text: String, epoch: Int?)
    case themeColors(ThemeColors)
    case headingColors(HeadingColors)
    case editorConfig(JSONValue)
    case hsnips(content: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, language, editorConfig, colors, config, content, epoch
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .initialize(text, language, editorConfig, epoch):
            try c.encode("init", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encode(language, forKey: .language)
            try c.encodeIfPresent(editorConfig, forKey: .editorConfig)
            try c.encodeIfPresent(epoch, forKey: .epoch)
        case let .update(text, epoch):
            try c.encode("update", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(epoch, forKey: .epoch)
        case let .themeColors(colors):
            try c.encode("theme-colors", forKey: .type)
            try c.encode(colors, forKey: .colors)
        case let .headingColors(colors):
            try c.encode("heading-colors", forKey: .type)
            try c.encode(colors, forKey: .colors)
        case let .editorConfig(config):
            try c.encode("editor-config", forKey: .type)
            try c.encode(config, forKey: .config)
        case let .hsnips(content):
            try c.encode("hsnips", forKey: .type)
            try c.encode(content, forKey: .content)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "init":
            self = .initialize(
                text: try c.decode(String.self, forKey: .text),
                language: try c.decode(EditorLanguage.self, forKey: .language),
                editorConfig: try c.decodeIfPresent(JSONValue.self, forKey: .editorConfig),
                epoch: try c.decodeIfPresent(Int.self, forKey: .epoch)
            )
        case "update":
            self = .update(
                text: try c.decode(String.self, forKey: .text),
                epoch: try c.decodeIfPresent(Int.self, forKey: .epoch))
        case "theme-colors":
            self = .themeColors(try c.decode(ThemeColors.self, forKey: .colors))
        case "heading-colors":
            self = .headingColors(try c.decode(HeadingColors.self, forKey: .colors))
        case "editor-config":
            self = .editorConfig(try c.decode(JSONValue.self, forKey: .config))
        case "hsnips":
            self = .hsnips(content: try c.decode(String.self, forKey: .content))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown host→editor message type: \(type)"
            )
        }
    }
}

/// Editor → host (the 3 outbound message types).
public enum EditorToHostMessage: Codable, Sendable, Equatable {
    case ready
    /// `epoch`: echo of the last applied init/update's epoch; nil when none
    /// was received (VS Code host).
    case edit(text: String, epoch: Int?)
    case openExternal(url: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, url, epoch
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ready:
            try c.encode("ready", forKey: .type)
        case let .edit(text, epoch):
            try c.encode("edit", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(epoch, forKey: .epoch)
        case let .openExternal(url):
            try c.encode("open-external", forKey: .type)
            try c.encode(url, forKey: .url)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "ready":
            self = .ready
        case "edit":
            self = .edit(
                text: try c.decode(String.self, forKey: .text),
                epoch: try c.decodeIfPresent(Int.self, forKey: .epoch))
        case "open-external":
            self = .openExternal(url: try c.decode(String.self, forKey: .url))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown editor→host message type: \(type)"
            )
        }
    }
}
