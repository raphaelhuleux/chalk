import Foundation

/// A shortcut the web layer forwards over the transport-internal `command`
/// message, so a focused WKWebView that swallows a Cmd-key before the menu
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
}
