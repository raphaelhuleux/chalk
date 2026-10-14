import Foundation

/// What a connecting scene opens with, decided for
/// `SceneDelegate.scene(_:willConnectTo:)`. Ghost scenes: see
/// docs/issues/2026-07-24-blank-editor-on-open.md.
public enum SceneConnectContent: Equatable {
    case restoreSession(WindowSession)
    case openEmpty
    case openWelcome
}

public enum SceneLaunchPolicy {
    /// A session without a usable restoration activity gets Welcome only as
    /// the process's first application scene. Later ones are ghosts and open
    /// empty, costing nothing before the settle sweep destroys them.
    public static func initialContent(
        restoredSession: WindowSession?,
        isNewWindowRequest: Bool,
        hasURLContexts: Bool,
        isFirstApplicationScene: Bool,
        isRestorationDisabled: Bool
    ) -> SceneConnectContent {
        if isRestorationDisabled {
            return isFirstApplicationScene ? .openWelcome : .openEmpty
        }
        if let restoredSession { return .restoreSession(restoredSession) }
        if isNewWindowRequest { return .openEmpty }
        // Cold Finder/Files open: the URL becomes the only tab, no Welcome.
        if hasURLContexts { return .openEmpty }
        return isFirstApplicationScene ? .openWelcome : .openEmpty
    }

    /// Launch-settle sweep: indices of scenes to destroy, given each scene's
    /// tab count (drafts included). Empties go, but one is kept if all are
    /// empty.
    public static func launchSweepVictims(openTabCounts: [Int]) -> [Int] {
        guard openTabCounts.count > 1 else { return [] }
        let empties = openTabCounts.indices.filter { openTabCounts[$0] == 0 }
        guard empties.count < openTabCounts.count else {
            return Array(empties.dropFirst())
        }
        return empties
    }
}
