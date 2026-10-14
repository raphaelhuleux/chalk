import Foundation

/// Session-only titles for unsaved draft tabs. Numbers come from open drafts
/// only, so closing one reclaims its number; the filename is chosen at save.
public enum DraftNaming {
    /// The lowest free title given the titles of the drafts already open.
    public static func nextUntitledTitle(existing: [String]) -> String {
        let taken = Set(existing)
        return FileNaming.uniqueName(base: "Untitled", ext: nil, isTaken: taken.contains)
    }
}
