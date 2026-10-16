import Foundation

/// Each window keeps its own Location list, stored under a key derived from its window id.
/// UserDefaults rather than the window journal: written on every change, so a folder added just
/// before a crash is kept.
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

    /// Every record in every per-window list whose window id does NOT start with `idPrefix`,
    /// deduplicated by id, first seen first: what another shell's windows showed. The Catalyst
    /// shell keyed its lists by scene session, which the AppKit shell cannot bring back, so its
    /// first launch seeds its first window from the union of them.
    public static func records(ofWindowsNotPrefixed idPrefix: String,
                               defaults: UserDefaults = .standard) -> [LocationRecord] {
        var seen = Set<String>()
        var merged: [LocationRecord] = []
        let keys = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(keyPrefix) && !$0.hasPrefix(keyPrefix + idPrefix) }
            .sorted()
        for key in keys {
            guard let data = defaults.data(forKey: key),
                  let records = try? JSONDecoder().decode([LocationRecord].self, from: data) else { continue }
            for record in records where seen.insert(record.id).inserted { merged.append(record) }
        }
        return merged
    }

    /// Whether any window of the shell whose ids start with `idPrefix` has a list yet.
    public static func hasAnyList(withIDPrefix idPrefix: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix(keyPrefix + idPrefix) }
    }

    /// Give `windowID` the list `records`, only when it has none yet.
    public static func seedIfAbsent(window windowID: String, with records: [LocationRecord],
                                    defaults: UserDefaults = .standard) {
        let key = key(forWindow: windowID)
        guard defaults.object(forKey: key) == nil, !records.isEmpty,
              let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
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
