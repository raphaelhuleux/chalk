import Foundation

/// Editing mode, cycled by the pill's mode button. The raw value is editor-core's `editingMode` wire
/// value, and declaration order is the pill's cycle (`next`).
public enum EditingMode: String, CaseIterable, Sendable {
    case normal, zen, typewriter, focus

    public var title: String {
        switch self {
        case .normal: return "Normal"
        case .zen: return "Zen"
        case .typewriter: return "Typewriter"
        case .focus: return "Focus"
        }
    }

    /// SF Symbol shown on the pill button while this mode is active.
    public var symbol: String {
        switch self {
        case .normal: return "doc.plaintext"
        case .zen: return "arrow.up.left.and.arrow.down.right"
        case .typewriter: return "align.vertical.center"
        case .focus: return "scope"
        }
    }
}

/// The view mode every editor opens in. The raw value is editor-core's `viewMode` wire value; Cmd+:
/// cycles one editor inside editor-core without touching this default, in declaration order.
public enum ViewMode: String, CaseIterable, Sendable {
    case preview, mixed, source

    public var title: String {
        switch self {
        case .preview: return "Preview"
        case .mixed: return "Mixed"
        case .source: return "Source"
        }
    }
}

public extension CaseIterable where Self: Equatable {
    /// The case after this one in declaration order, wrapping to the first.
    var next: Self {
        let all = Self.allCases
        let after = all.index(after: all.firstIndex(of: self)!)
        return after == all.endIndex ? all[all.startIndex] : all[after]
    }
}

/// App appearance preference (Light/Dark/Auto). Each shell maps it to its own window appearance
/// override. The colour theme is separate: `Preferences.colorTheme`.
public enum ThemePreference: Int, CaseIterable, Sendable {
    case auto = 0
    case light
    case dark

    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// File type for new documents (Sidebar New File, first save of a Cmd+N draft). The raw value is
/// the file extension; detection for existing files lives in `EditorLanguage(fileExtension:)`.
public enum DefaultFileType: String, CaseIterable, Sendable {
    case md, tex

    public var title: String {
        switch self {
        case .md: return "Markdown"
        case .tex: return "LaTeX"
        }
    }

    /// Extension for a newly created file (no leading dot).
    public var fileExtension: String { rawValue }

    /// Language to seed a draft's editor with, so a LaTeX draft gets LaTeX
    /// snippets and syntax before it has a file on disk.
    public var language: EditorLanguage { EditorLanguage(fileExtension: rawValue) }
}

/// Alignment of wrapped prose, pushed to the page as --chalk-text-align. `justified` works under
/// CodeMirror's `white-space: pre-wrap` in both WebKit and Chromium.
public enum EditorTextAlignment: String, CaseIterable, Sendable {
    case left, justified

    public var title: String {
        switch self {
        case .left: return "Left"
        case .justified: return "Justified"
        }
    }

    /// The CSS `text-align` value. `start` rather than `left` so an RTL
    /// document flips with the writing direction.
    public var cssValue: String {
        switch self {
        case .left: return "start"
        case .justified: return "justify"
        }
    }
}

/// App preferences (UserDefaults-backed), edited by the Settings screen. Shared by both shells, so
/// an upgrade between them keeps every setting: the keys here never change.
///
/// Column widths are NOT here: the shell owns them (`Preferences+AppKit.swift`), with the one-time
/// conversion from the Catalyst install's iPad-idiom points.
public enum Preferences {
    private static let fontScaleKey = "chalk.editorFontScale"
    private static let themeKey = "chalk.themePreference"
    private static let colorThemeKey = "chalk.colorTheme"
    private static let editingModeKey = "chalk.editingMode"
    private static let viewModeKey = "chalk.viewMode"
    private static let autoHideChromeKey = "chalk.autoHideChrome"
    private static let editorMeasureKey = "chalk.editorMeasure"
    private static let editorLineHeightKey = "chalk.editorLineHeight"
    private static let textAlignmentKey = "chalk.textAlignment"
    private static let defaultFileTypeKey = "chalk.defaultFileType"
    private static let colorHeadingsKey = "chalk.colorHeadings"

    /// Posted when `autoHideChrome` changes. Settings runs in its own window, so every open window
    /// re-applies from this notification.
    public static let autoHideChromeDidChange = Notification.Name("chalk.autoHideChromeDidChange")

    /// Bounds for the editor text zoom. The Settings slider spans exactly this.
    public static let editorFontScaleRange: ClosedRange<Double> = 0.6...2.5

    /// Editor text zoom, 1.0 = base 17px (`WebEditorSurface.baseFontSize`). Clamped on write.
    public static var editorFontScale: Double {
        get {
            let value = UserDefaults.standard.double(forKey: fontScaleKey)
            return value == 0 ? 1.0 : value
        }
        set {
            UserDefaults.standard.set(clamp(newValue, to: editorFontScaleRange), forKey: fontScaleKey)
        }
    }

    /// Dark until the user picks otherwise.
    public static var themePreference: ThemePreference {
        get {
            guard UserDefaults.standard.object(forKey: themeKey) != nil else { return .dark }
            return ThemePreference(rawValue: UserDefaults.standard.integer(forKey: themeKey)) ?? .dark
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: themeKey) }
    }

    /// The colour theme, Atom by default. Unknown raw values (from a future build) fall back to it.
    public static var colorTheme: ChalkTheme {
        get {
            let raw = UserDefaults.standard.string(forKey: colorThemeKey) ?? ""
            return ChalkTheme(rawValue: raw) ?? .atom
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: colorThemeKey) }
    }

    /// Last-used editing mode. Unknown raw values (from a future build) fall back to normal.
    public static var editingMode: EditingMode {
        get {
            let raw = UserDefaults.standard.string(forKey: editingModeKey) ?? ""
            return EditingMode(rawValue: raw) ?? .normal
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: editingModeKey) }
    }

    /// Default view mode, persisted. Unknown raw values fall back to preview.
    public static var viewMode: ViewMode {
        get {
            let raw = UserDefaults.standard.string(forKey: viewModeKey) ?? ""
            return ViewMode(rawValue: raw) ?? .preview
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: viewModeKey) }
    }

    /// The `editor-config` payload. editor-core resets any field left out to its default, so every
    /// shell-owned field must travel in one message.
    ///
    /// `editingMode` is per window: a broadcast to one window must pass that window's mode, or a
    /// zen window's editors would take another window's mode while its chrome stays in zen. The
    /// default argument is only for callers with no window.
    public static func editorConfigPayload(editingMode: EditingMode = Preferences.editingMode) -> JSONValue {
        .object([
            "editingMode": .string(editingMode.rawValue),
            "viewMode": .string(viewMode.rawValue),
            "markdownStyle": .string(colorTheme.markdownStyle),
        ])
    }

    /// Scrolling down slides the tab band and the utility pill away, scrolling up returns them.
    /// On by default.
    public static var autoHideChrome: Bool {
        get {
            guard UserDefaults.standard.object(forKey: autoHideChromeKey) != nil
            else { return true }
            return UserDefaults.standard.bool(forKey: autoHideChromeKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoHideChromeKey) }
    }

    /// Color Markdown headings per level with the baked `MarkdownHeadingPalette`, like the VS Code
    /// extension. Off by default: the shell's type system styles headings by weight, not hue.
    public static var colorHeadings: Bool {
        get { UserDefaults.standard.bool(forKey: colorHeadingsKey) }
        set { UserDefaults.standard.set(newValue, forKey: colorHeadingsKey) }
    }

    /// Bounds for the text column. The upper end is wider than any default window, so it
    /// effectively means "no column limit".
    public static let editorMeasureRange: ClosedRange<Double> = 480...1400

    /// Width of the centered text column in CSS px, including side padding (border-box). Clamped on
    /// read and write. The 960 default matches chalk-theme.css, which stays the pre-`ready` fallback.
    public static var editorMeasure: Double {
        get { storedDouble(editorMeasureKey, default: 960, in: editorMeasureRange) }
        set { setStoredDouble(newValue, editorMeasureKey, in: editorMeasureRange) }
    }

    /// Bounds for the unitless CSS line-height multiplier.
    public static let editorLineHeightRange: ClosedRange<Double> = 1.1...2.4

    /// Line spacing, pushed to the page as --chalk-line-height-pref. Clamped on read and write. The
    /// 1.6 default matches chalk-theme.css, which stays the pre-`ready` fallback.
    public static var editorLineHeight: Double {
        get { storedDouble(editorLineHeightKey, default: 1.6, in: editorLineHeightRange) }
        set { setStoredDouble(newValue, editorLineHeightKey, in: editorLineHeightRange) }
    }

    /// Wrapped-prose alignment. Unknown raw values fall back to left.
    public static var textAlignment: EditorTextAlignment {
        get {
            let raw = UserDefaults.standard.string(forKey: textAlignmentKey) ?? ""
            return EditorTextAlignment(rawValue: raw) ?? .left
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: textAlignmentKey) }
    }

    /// File type for new documents. Unknown raw values fall back to Markdown.
    public static var defaultFileType: DefaultFileType {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultFileTypeKey) ?? ""
            return DefaultFileType(rawValue: raw) ?? .md
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultFileTypeKey) }
    }

    // MARK: - Clamped numbers

    /// A stored number, `fallback` when unset (UserDefaults reads a missing
    /// Double as 0), clamped into `range` so a stale or out-of-range value from
    /// another build can never wedge the UI. Public for the shells' own
    /// clamped preferences (the column widths).
    public static func storedDouble(
        _ key: String, default fallback: Double, in range: ClosedRange<Double>
    ) -> Double {
        let value = UserDefaults.standard.double(forKey: key)
        return clamp(value == 0 ? fallback : value, to: range)
    }

    public static func setStoredDouble(_ value: Double, _ key: String, in range: ClosedRange<Double>) {
        UserDefaults.standard.set(clamp(value, to: range), forKey: key)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
