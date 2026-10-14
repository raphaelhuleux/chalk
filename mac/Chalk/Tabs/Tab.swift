import Foundation

/// One open document: its own editor surface + document controller, so each tab
/// keeps its own cursor, scroll and undo history. The surface stays dormant
/// until the tab is first shown (`bootIfNeeded`).
///
/// The surface is held as the `EditorSurface` protocol, not the concrete web
/// one: this is the swap seam, and holding `WebEditorSurface` lets the shell
/// reach past it.
///
/// `url` is nil for a draft (Cmd+N): the document exists only in memory until
/// the first save binds it to a file. `draftTitle` is the session-only chip
/// title for that window ("Untitled", "Untitled 2", …).
final class Tab {
    let id = UUID()
    var url: URL?
    let draftTitle: String?
    var isDirty = false
    /// A "committed" tab is a permanent tab: the user has either edited it or
    /// explicitly saved it (Cmd+S, even with no changes — an automatic
    /// background `saveAll` does NOT count). Sticky. An uncommitted,
    /// file-backed tab is a transient "preview" (iA Writer): shown slanted, and
    /// a sidebar browse-click reuses it in place. Committing it stops both.
    var isCommitted = false
    let surface: EditorSurface
    let controller: DocumentController

    init(url: URL) {
        self.url = url
        self.draftTitle = nil
        let surface = WebEditorSurface()
        self.surface = surface
        self.controller = DocumentController(surface: surface)
    }

    init(draftTitle: String) {
        self.url = nil
        self.draftTitle = draftTitle
        let surface = WebEditorSurface()
        self.surface = surface
        self.controller = DocumentController(surface: surface)
    }

    var displayName: String { url?.lastPathComponent ?? draftTitle ?? "Untitled" }
}
