import Foundation
import ChalkKit

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
    var url: URL? {
        didSet { cachedIdentity = nil }
    }
    private var cachedIdentity: String?

    /// `url.fileIdentity`, resolved once per URL: every open and every save
    /// anywhere compares it against each tab.
    var fileIdentity: String? {
        if let cached = cachedIdentity { return cached }
        guard let url else { return nil }
        let identity = url.fileIdentity
        cachedIdentity = identity
        return identity
    }
    let draftTitle: String?
    var isDirty = false
    /// A "committed" tab is a permanent tab: the user has either edited it or
    /// explicitly saved it (Cmd+S, even with no changes; an automatic
    /// background `saveAll` does NOT count). Sticky. An uncommitted,
    /// file-backed tab is a transient "preview" (iA Writer): shown slanted, and
    /// a sidebar browse-click reuses it in place. Committing it stops both.
    var isCommitted = false
    /// The trailing slot shows this tab's compiled PDF while it is active (⌥⌘P, Compile).
    /// Per tab, unlike the outline, which the window keeps.
    var showsPDF = false
    let surface: EditorSurface
    let controller: DocumentController

    convenience init(url: URL) { self.init(url: url, draftTitle: nil) }
    convenience init(draftTitle: String) { self.init(url: nil, draftTitle: draftTitle) }

    private init(url: URL?, draftTitle: String?) {
        self.url = url
        self.draftTitle = draftTitle
        let surface = WebEditorSurface()
        self.surface = surface
        self.controller = DocumentController(surface: surface)
    }

    var displayName: String { url?.lastPathComponent ?? draftTitle ?? "Untitled" }

    /// The journal's record for this tab. The security-scoped bookmark is
    /// minted once per file (a sandbox call) and kept until the tab's URL
    /// changes, since the journal is written on every deactivation.
    func sessionRecord() -> WindowSession.TabRecord? {
        guard let url else { return nil }
        if let cached = cachedBookmark, cached.url == url {
            return WindowSession.TabRecord(path: url.path, bookmark: cached.data)
        }
        let data = FileBookmark.make(for: url)
        cachedBookmark = (url, data)
        return WindowSession.TabRecord(path: url.path, bookmark: data)
    }
    private var cachedBookmark: (url: URL, data: Data?)?
}
