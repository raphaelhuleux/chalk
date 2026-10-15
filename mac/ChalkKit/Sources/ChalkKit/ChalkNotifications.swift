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

/// Activity and restoration type identifiers. The Catalyst shell carries them
/// on `NSUserActivity`; the AppKit shell's `NSWindowRestoration` state uses the
/// same `windowType` and `stateKey` so a `WindowSession` reads the same either way.
public enum ChalkActivity {
    /// Window-restoration snapshot (a `WindowSession` in userInfo["state"]).
    public static let windowType = "com.huleux.chalk.window"
    /// File > New Window: a deliberately fresh window (empty, no Welcome).
    public static let newWindowType = "com.huleux.chalk.newWindow"
    public static let stateKey = "state"
    /// The file a New Window request should open, if any (a file URL). Absent
    /// for File > New Window, present for the sidebar's "Open in New Window".
    public static let urlKey = "url"
    /// A folder the new window opens on (bookmark data, minted while the sender held its scope), for a
    /// folder handed to the app from outside (`ExternalOpenRouter`).
    public static let folderBookmarkKey = "folderBookmark"
    /// Marks the Settings scene on Mac, where Settings is a real resizable
    /// window rather than a sheet. Deliberately absent from
    /// `stateRestorationActivity`: a Settings window must not come back on
    /// relaunch.
    public static let settingsType = "com.huleux.chalk.settings"
}
