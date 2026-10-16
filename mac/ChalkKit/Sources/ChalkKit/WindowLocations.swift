import Foundation

/// Each window keeps its own Location list, stored under a key derived from its scene session's
/// persistent identifier. UserDefaults rather than the restoration activity: the OS captures that only
/// when the scene backgrounds, so a folder added just before a crash would be lost.
public enum WindowLocations {
    /// The app-wide list from before Locations were per window. Read for migration, never written or
    /// deleted: an older build reading the same domain still finds it.
    public static let legacyKey = "chalk.locations"
    static let migratedFlagKey = "chalk.locations.migratedToWindows"
    static let keyPrefix = "chalk.window-locations."

    public static func key(forWindow windowID: String) -> String { keyPrefix + windowID }

    /// The store for one window, created on first use. A window with no list yet inherits the legacy
    /// list when it predates per-window lists (`isRestoredWindow`), or when it is the first window
    /// since the update and nothing was restored; every other new window starts empty.
    public static func store(
        forWindow windowID: String, isRestoredWindow: Bool, defaults: UserDefaults = .standard
    ) -> BookmarkStore {
        let key = key(forWindow: windowID)
        if defaults.object(forKey: key) == nil {
            let inherits = isRestoredWindow || !defaults.bool(forKey: migratedFlagKey)
            if inherits, let legacy = defaults.data(forKey: legacyKey) {
                defaults.set(legacy, forKey: key)
            } else {
                defaults.set(Data("[]".utf8), forKey: key)
            }
            defaults.set(true, forKey: migratedFlagKey)
        }
        return BookmarkStore(defaults: defaults, key: key)
    }

    /// Forget the lists of windows the OS discarded (closed for good).
    public static func discard(windows windowIDs: [String], defaults: UserDefaults = .standard) {
        for id in windowIDs { defaults.removeObject(forKey: key(forWindow: id)) }
    }

    /// Forget every per-window list whose window id starts with `idPrefix` except those of
    /// `windowIDs`: the windows the shell can still bring back. A process that died before it first
    /// journaled a window leaves that window's list behind with no way to reach it. The prefix keeps
    /// one shell's sweep off another shell's lists in the same domain, and the legacy app-wide list
    /// is never touched.
    public static func discardAll(except windowIDs: [String], idPrefix: String,
                                  defaults: UserDefaults = .standard) {
        let keep = Set(windowIDs.map(key(forWindow:)))
        let swept = keyPrefix + idPrefix
        for stored in defaults.dictionaryRepresentation().keys
        where stored.hasPrefix(swept) && !keep.contains(stored) {
            defaults.removeObject(forKey: stored)
        }
    }
}
