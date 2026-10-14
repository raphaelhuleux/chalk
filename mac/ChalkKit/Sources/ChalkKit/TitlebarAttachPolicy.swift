import Foundation

/// Whether the AppKit glue should attach its titlebar tab-strip controller to
/// a window: the predicate behind `ChalkAppKitGlue.styleAllWindows`, here so
/// it can be unit-tested (compiled into the glue, see mac/project.yml).
public enum TitlebarAttachPolicy {
    /// Only primary scene windows: miniaturizable excludes Catalyst's titled
    /// form-sheet windows (e.g. Settings); `hasNoChromeTitle` is the app's
    /// no-chrome title prefix. Attach exactly once per window.
    public static func shouldAttach(
        isTitled: Bool,
        isMiniaturizable: Bool,
        isSheet: Bool,
        hasParent: Bool,
        hasNoChromeTitle: Bool,
        alreadyAttached: Bool
    ) -> Bool {
        isTitled && isMiniaturizable && !isSheet && !hasParent
            && !hasNoChromeTitle && !alreadyAttached
    }
}
