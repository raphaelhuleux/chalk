import UIKit
import ChalkKit

/// Editing mode, cycled by the pill's mode button. The raw value is editor-core's `editingMode` wire
/// value, and declaration order is the pill's cycle (`next`).
enum EditingMode: String, CaseIterable {
    case normal, zen, typewriter, focus

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .zen: return "Zen"
        case .typewriter: return "Typewriter"
        case .focus: return "Focus"
        }
    }

    /// SF Symbol shown on the pill button while this mode is active.
    var symbol: String {
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
enum ViewMode: String, CaseIterable {
    case preview, mixed, source

    var title: String {
        switch self {
        case .preview: return "Preview"
        case .mixed: return "Mixed"
        case .source: return "Source"
        }
    }
}

extension CaseIterable where Self: Equatable {
    /// The case after this one in declaration order, wrapping to the first.
    var next: Self {
        let all = Self.allCases
        let after = all.index(after: all.firstIndex(of: self)!)
        return after == all.endIndex ? all[all.startIndex] : all[after]
    }
}

/// App appearance preference (Light/Dark/Auto), mapped to the window's interface style override.
/// The colour theme is separate: `Preferences.colorTheme`.
enum ThemePreference: Int, CaseIterable {
    case auto = 0
    case light
    case dark

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .auto: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// File type for new documents (Sidebar New File, first save of a Cmd+N draft). The raw value is
/// the file extension; detection for existing files lives in `EditorLanguage(fileExtension:)`.
enum DefaultFileType: String, CaseIterable {
    case md, tex

    var title: String {
        switch self {
        case .md: return "Markdown"
        case .tex: return "LaTeX"
        }
    }

    /// Extension for a newly created file (no leading dot).
    var fileExtension: String { rawValue }

    /// Language to seed a draft's editor with, so a LaTeX draft gets LaTeX
    /// snippets and syntax before it has a file on disk.
    var language: EditorLanguage { EditorLanguage(fileExtension: rawValue) }
}

/// Alignment of wrapped prose, pushed to the page as --chalk-text-align. `justified` works under
/// CodeMirror's `white-space: pre-wrap` in both WebKit and Chromium.
enum EditorTextAlignment: String, CaseIterable {
    case left, justified

    var title: String {
        switch self {
        case .left: return "Left"
        case .justified: return "Justified"
        }
    }

    /// The CSS `text-align` value. `start` rather than `left` so an RTL
    /// document flips with the writing direction.
    var cssValue: String {
        switch self {
        case .left: return "start"
        case .justified: return "justify"
        }
    }
}

/// Lightweight app preferences (UserDefaults-backed), edited by SettingsViewController.
enum Preferences {
    private static let fontScaleKey = "chalk.editorFontScale"
    private static let themeKey = "chalk.themePreference"
    private static let colorThemeKey = "chalk.colorTheme"
    private static let sidebarWidthKey = "chalk.sidebarWidth"
    private static let outlinePanelWidthKey = "chalk.outlinePanelWidth"
    private static let editingModeKey = "chalk.editingMode"
    private static let viewModeKey = "chalk.viewMode"
    private static let autoHideChromeKey = "chalk.autoHideChrome"
    private static let editorMeasureKey = "chalk.editorMeasure"
    private static let editorLineHeightKey = "chalk.editorLineHeight"
    private static let textAlignmentKey = "chalk.textAlignment"
    private static let defaultFileTypeKey = "chalk.defaultFileType"
    private static let colorHeadingsKey = "chalk.colorHeadings"

    /// Posted when `autoHideChrome` changes. Settings runs in its own scene, so every open window
    /// re-applies from this notification.
    static let autoHideChromeDidChange = Notification.Name("chalk.autoHideChromeDidChange")

    /// Bounds for the resizable Library column. The Catalyst min window (880x560) still clears a
    /// 560pt sidebar plus a ~320pt editor column.
    static let sidebarWidthRange: ClosedRange<CGFloat> = 220...560

    /// Last-used Library column width. Clamped on read and write so a stale value can never wedge
    /// the column.
    static var sidebarWidth: CGFloat {
        get { CGFloat(clampedDouble(sidebarWidthKey, default: Double(ChalkMetrics.sidebarWidth),
                                    in: widthRange)) }
        set { setClampedDouble(Double(newValue), sidebarWidthKey, in: widthRange) }
    }

    /// Last-used outline panel width (⌘K), persisted like `sidebarWidth` and
    /// clamped into the same range.
    static var outlinePanelWidth: CGFloat {
        get { CGFloat(clampedDouble(outlinePanelWidthKey, default: Double(ChalkMetrics.sidebarWidth),
                                    in: widthRange)) }
        set { setClampedDouble(Double(newValue), outlinePanelWidthKey, in: widthRange) }
    }

    private static var widthRange: ClosedRange<Double> {
        Double(sidebarWidthRange.lowerBound)...Double(sidebarWidthRange.upperBound)
    }

    /// Bounds for the editor text zoom. The Settings slider spans exactly this.
    static let editorFontScaleRange: ClosedRange<Double> = 0.6...2.5

    /// Editor text zoom, 1.0 = base 17px (`WebEditorSurface.baseFontSize`). Clamped on write.
    static var editorFontScale: Double {
        get {
            let value = UserDefaults.standard.double(forKey: fontScaleKey)
            return value == 0 ? 1.0 : value
        }
        set {
            UserDefaults.standard.set(clamp(newValue, to: editorFontScaleRange), forKey: fontScaleKey)
        }
    }

    /// Dark until the user picks otherwise.
    static var themePreference: ThemePreference {
        get {
            guard UserDefaults.standard.object(forKey: themeKey) != nil else { return .dark }
            return ThemePreference(rawValue: UserDefaults.standard.integer(forKey: themeKey)) ?? .dark
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: themeKey) }
    }

    /// The colour theme, Atom by default. Unknown raw values (from a future build) fall back to it.
    static var colorTheme: ChalkTheme {
        get {
            let raw = UserDefaults.standard.string(forKey: colorThemeKey) ?? ""
            return ChalkTheme(rawValue: raw) ?? .atom
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: colorThemeKey) }
    }

    /// Last-used editing mode. Unknown raw values (from a future build) fall back to normal.
    static var editingMode: EditingMode {
        get {
            let raw = UserDefaults.standard.string(forKey: editingModeKey) ?? ""
            return EditingMode(rawValue: raw) ?? .normal
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: editingModeKey) }
    }

    /// Default view mode, persisted. Unknown raw values fall back to preview.
    static var viewMode: ViewMode {
        get {
            let raw = UserDefaults.standard.string(forKey: viewModeKey) ?? ""
            return ViewMode(rawValue: raw) ?? .preview
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: viewModeKey) }
    }

    /// The `editor-config` payload. editor-core resets any field left out to its default, so every
    /// shell-owned field must travel in one message.
    ///
    /// `editingMode` is per window (`RootSplitViewController.editingMode`): a broadcast to one
    /// window must pass that window's mode, or a zen window's editors would take another window's
    /// mode while its chrome stays in zen. The default argument is only for callers with no window.
    static func editorConfigPayload(editingMode: EditingMode = Preferences.editingMode) -> JSONValue {
        .object([
            "editingMode": .string(editingMode.rawValue),
            "viewMode": .string(viewMode.rawValue),
            "markdownStyle": .string(colorTheme.markdownStyle),
        ])
    }

    /// Scrolling down slides the tab band and the utility pill away, scrolling up returns them.
    /// On by default.
    static var autoHideChrome: Bool {
        get {
            guard UserDefaults.standard.object(forKey: autoHideChromeKey) != nil
            else { return true }
            return UserDefaults.standard.bool(forKey: autoHideChromeKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoHideChromeKey) }
    }

    /// Color Markdown headings per level with the baked `MarkdownHeadingPalette`, like the VS Code
    /// extension. Off by default: the shell's type system styles headings by weight, not hue.
    static var colorHeadings: Bool {
        get { UserDefaults.standard.bool(forKey: colorHeadingsKey) }
        set { UserDefaults.standard.set(newValue, forKey: colorHeadingsKey) }
    }

    /// Bounds for the text column. The upper end is wider than any default window, so it
    /// effectively means "no column limit".
    static let editorMeasureRange: ClosedRange<Double> = 480...1400

    /// Width of the centered text column in CSS px, including side padding (border-box). Clamped on
    /// read and write. The 960 default matches chalk-theme.css, which stays the pre-`ready` fallback.
    static var editorMeasure: Double {
        get { clampedDouble(editorMeasureKey, default: 960, in: editorMeasureRange) }
        set { setClampedDouble(newValue, editorMeasureKey, in: editorMeasureRange) }
    }

    /// Bounds for the unitless CSS line-height multiplier.
    static let editorLineHeightRange: ClosedRange<Double> = 1.1...2.4

    /// Line spacing, pushed to the page as --chalk-line-height-pref. Clamped on read and write. The
    /// 1.6 default matches chalk-theme.css, which stays the pre-`ready` fallback.
    static var editorLineHeight: Double {
        get { clampedDouble(editorLineHeightKey, default: 1.6, in: editorLineHeightRange) }
        set { setClampedDouble(newValue, editorLineHeightKey, in: editorLineHeightRange) }
    }

    // MARK: - Clamped numbers

    /// A stored number, `fallback` when unset (UserDefaults reads a missing
    /// Double as 0), clamped into `range` so a stale or out-of-range value from
    /// another build can never wedge the UI.
    private static func clampedDouble(
        _ key: String, default fallback: Double, in range: ClosedRange<Double>
    ) -> Double {
        let value = UserDefaults.standard.double(forKey: key)
        return clamp(value == 0 ? fallback : value, to: range)
    }

    private static func setClampedDouble(_ value: Double, _ key: String, in range: ClosedRange<Double>) {
        UserDefaults.standard.set(clamp(value, to: range), forKey: key)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    /// Wrapped-prose alignment. Unknown raw values fall back to left.
    static var textAlignment: EditorTextAlignment {
        get {
            let raw = UserDefaults.standard.string(forKey: textAlignmentKey) ?? ""
            return EditorTextAlignment(rawValue: raw) ?? .left
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: textAlignmentKey) }
    }

    /// File type for new documents. Unknown raw values fall back to Markdown.
    static var defaultFileType: DefaultFileType {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultFileTypeKey) ?? ""
            return DefaultFileType(rawValue: raw) ?? .md
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultFileTypeKey) }
    }
}

extension UIViewController {
    /// Pins this controller to the app's light/dark preference and colour theme. Needed wherever a
    /// controller may land in its own UIWindow (Catalyst form sheets, alerts) and would drift to
    /// the system style and the default theme.
    func applyChalkAppearance() {
        overrideUserInterfaceStyle = Preferences.themePreference.interfaceStyle
        traitOverrides.chalkTheme = Preferences.colorTheme
    }

    /// Present above whatever is already presented: UIKit silently drops a presentation on a
    /// controller that is presenting something else (a sheet, another alert).
    func presentOnTop(_ controller: UIViewController) {
        var host: UIViewController = self
        while let presented = host.presentedViewController, !presented.isBeingDismissed {
            host = presented
        }
        host.present(controller, animated: true)
    }

    /// A one-button notice in the app's appearance, presented on top.
    func presentChalkNotice(title: String?, message: String?) {
        presentOnTop(UIAlertController.chalkNotice(title: title, message: message))
    }
}

extension UIAlertController {
    /// An OK-only alert pinned to the app's appearance: on Catalyst an alert is its own window and
    /// would otherwise follow the system's.
    static func chalkNotice(title: String?, message: String?) -> UIAlertController {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.applyChalkAppearance()
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        return alert
    }
}
