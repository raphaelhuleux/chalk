import Foundation
import UIKit

/// Cross-window signals. Every window observes these so state that is shared
/// across scenes (the Location library, files open in more than one window)
/// stays live everywhere, not just in the window that made the change.
extension Notification.Name {
    /// The Location library changed (add/remove/reauthorize, or a draft was
    /// saved into a Location). Windows respond by reloading their sidebar tree.
    static let chalkLibraryDidChange = Notification.Name("chalk.libraryDidChange")
    /// A document was saved. `object` is the posting DocumentController;
    /// userInfo carries `ChalkNotificationKey.url`. Other windows with the same
    /// file open reload if their buffer is clean.
    static let chalkDocumentDidSave = Notification.Name("chalk.documentDidSave")
    /// A file or folder was renamed/moved from a sidebar. userInfo carries
    /// `ChalkNotificationKey.fromURL`/`.toURL`; every window remaps its tabs.
    static let chalkFileDidMove = Notification.Name("chalk.fileDidMove")
}

enum ChalkNotificationKey {
    static let url = "url"
    static let fromURL = "fromURL"
    static let toURL = "toURL"
}

enum ChalkActivity {
    /// Scene-restoration snapshot (a `WindowSession` in userInfo["state"]).
    static let windowType = "com.huleux.chalk.window"
    /// File > New Window: a deliberately fresh window (empty, no Welcome).
    static let newWindowType = "com.huleux.chalk.newWindow"
    static let stateKey = "state"
    /// The file a New Window request should open, if any (a file URL). Absent
    /// for File > New Window, present for the sidebar's "Open in New Window".
    static let urlKey = "url"
    /// A folder the new window opens on (bookmark data, minted while the sender held its scope), for a
    /// folder handed to the app from outside (`ExternalOpenRouter`).
    static let folderBookmarkKey = "folderBookmark"
    /// Marks the Settings scene on Mac, where Settings is a real resizable
    /// window rather than a sheet. Deliberately absent from
    /// `stateRestorationActivity`: a Settings window must not come back on
    /// relaunch.
    static let settingsType = "com.huleux.chalk.settings"
}

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
