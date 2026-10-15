import Foundation
import UIKit
import ChalkKit

/// Which scene delegate a connecting session gets. Pure so the routing rule is
/// testable without a GUI.
enum SceneRouting {
    case editor
    case settings
    /// A session role Chalk does not support (anything but a window).
    /// `DeclinedSceneDelegate` connects it and immediately asks for its
    /// destruction, which is the only way to say "no" from
    /// `configurationForConnecting` (it must return a configuration).
    case declined

    /// - Parameters:
    ///   - sessionRole: `UISceneSession.role` of the connecting session.
    ///   - activityTypes: `options.userActivities` types on the connecting session.
    ///   - restorationType: the session's persisted `stateRestorationActivity` type.
    static func role(
        sessionRole: UISceneSession.Role,
        activityTypes: [String],
        restorationType: String?
    ) -> SceneRouting {
        // Role first, above every activity check: a restored (or stale
        // Settings) activity would otherwise route a window into a session
        // that is not one.
        guard sessionRole == .windowApplication else { return .declined }
        if activityTypes.contains(ChalkActivity.settingsType) { return .settings }
        // A Settings session should never persist, but if a stale one survives
        // an upgrade it must still route somewhere sane rather than building an
        // editor inside the Settings window.
        if restorationType == ChalkActivity.settingsType { return .settings }
        return .editor
    }
}
