import Foundation

/// A shortcut the web layer forwards over the transport-internal `command`
/// message, so a focused WKWebView that swallows a shortcut before the menu
/// sees it still reaches the shell (`admitShellAction` dedupes the two lanes).
///
/// Mirrors `SHELL_COMMANDS` in web/src/native-host.ts (same raw values, same
/// order); change both. `ShellCommandTests` pins only this side.
public enum ShellCommand: String, CaseIterable, Codable, Sendable, Equatable {
    /// Cmd+S: the document's own save, not a shell action.
    case save
    /// Cmd+P: the outline palette.
    case toggleOutline = "toggle-outline"
    /// Cmd+K: the persistent outline panel.
    case toggleOutlinePanel = "toggle-outline-panel"
    /// Cmd+O: Quick Open.
    case quickOpen = "quick-open"
    /// Ctrl+Tab / Ctrl+Shift+Tab: cycle the tabs.
    case nextTab = "next-tab"
    case previousTab = "previous-tab"
    /// Cmd+Shift+Return: keep the AI text in the selection, or all of it.
    case acceptAiMarks = "accept-ai-marks"
    /// Cmd+Shift+Delete: drop it and restore what it deleted.
    case rejectAiMarks = "reject-ai-marks"
}
