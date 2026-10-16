import Foundation

/// One editor window as the AppKit shell writes it down: a stable identity
/// (the key its Locations live under, see `WindowLocations`), its tabs and
/// its frame on screen.
public struct WindowRecord: Codable, Equatable {
    /// Screen coordinates, as `NSRect` components; absent for a window that
    /// never reached the screen.
    public struct Frame: Codable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public let id: String
    public var session: WindowSession
    public var frame: Frame?

    public init(id: String, session: WindowSession, frame: Frame? = nil) {
        self.id = id
        self.session = session
        self.frame = frame
    }
}

/// The app's own window restoration. AppKit's `NSWindowRestoration` only runs
/// when the user's "Close windows when quitting an application" setting is
/// off, which it is not by default; this journal brings every window back
/// regardless. Written whenever the set of windows or the app's activity changes, read
/// once at launch. A window the user closes leaves it; a quit keeps every
/// window in it.
public final class WindowSessionJournal {
    public static let defaultKey = "chalk.windowSessions.appkit"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = WindowSessionJournal.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    /// Every window of the last session, in the order they were written
    /// (front to back). Empty on the first launch, after the last window was
    /// closed, or when the stored bytes no longer decode.
    public func load() -> [WindowRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([WindowRecord].self, from: data)) ?? []
    }

    /// Replace the journal. The complete list every time: a partial write
    /// would resurrect windows that were closed since.
    public func save(_ records: [WindowRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
