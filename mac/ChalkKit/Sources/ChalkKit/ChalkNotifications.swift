import Foundation

/// Cross-window signals. Every window observes these so state that is shared
/// across windows (the Location library, files open in more than one window)
/// stays live everywhere, not just in the window that made the change.
public extension Notification.Name {
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

public enum ChalkNotificationKey {
    public static let url = "url"
    public static let fromURL = "fromURL"
    public static let toURL = "toURL"
}
