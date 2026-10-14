import Foundation

/// A shortcut the web layer forwards over the transport-internal `command`
/// message: a focused WKWebView on Catalyst swallows some Cmd-keys before the
/// menu sees them.
///
/// Mirrors `SHELL_COMMANDS` in web/src/native-host.ts (same raw values, same
/// order); change both. `ShellCommandTests` pins only this side.
///
/// Foundation only, no other ChalkKit type: ChalkAppKitGlue compiles this
/// file in, so glue and app share one declaration of the raw values.
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
