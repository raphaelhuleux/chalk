import AppKit
import ChalkKit

/// Sends files and folders handed to the app from outside (Finder, Raycast
/// "Open With", `open -a Chalk <path>`, a drop on the Dock icon) to the right
/// window, VS Code style. The rules live in `ExternalOpenRouting`; this maps
/// them onto live windows. The windows and the new-window maker are handed in
/// so a test can route without `NSApp`.
enum ExternalOpenRouter {
    /// An editor window that may take the open, with the way to bring it forward.
    struct Candidate {
        let root: RootSplitViewController
        let bringForward: () -> Void
    }

    /// - Parameters:
    ///   - receiver: the window the open would land in by default: the key
    ///     editor window, else the frontmost.
    ///   - candidates: every editor window, frontmost first, so ties go to
    ///     the window the user is looking at.
    ///   - makeWindow: opens an empty window for a folder no window shows
    ///     when the receiver is already in use.
    static func route(_ urls: [URL],
                      receivedBy receiver: RootSplitViewController,
                      candidates: [Candidate],
                      makeWindow: () -> RootSplitViewController) {
        for url in urls { route(url, receivedBy: receiver, candidates: candidates, makeWindow: makeWindow) }
    }

    private static func route(_ url: URL,
                              receivedBy receiver: RootSplitViewController,
                              candidates: [Candidate],
                              makeWindow: () -> RootSplitViewController) {
        // The directory check and the bookmark `addFolderToWindow` mints both
        // need the sender's scope in the sandbox.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let roots = candidates.map { $0.root.libraryRoots.map(\.fileIdentity) }

        if isDirectory(url) {
            if let index = ExternalOpenRouting.windowShowing(folder: url.fileIdentity, windowRoots: roots) {
                candidates[index].bringForward()
            } else if receiver.isPristine {
                receiver.addFolderToWindow(url)
            } else {
                makeWindow().addFolderToWindow(url)
            }
            return
        }

        if let index = ExternalOpenRouting.windowContaining(file: url.fileIdentity, windowRoots: roots),
           candidates[index].root !== receiver {
            candidates[index].root.openExternalDocument(url)
            candidates[index].bringForward()
        } else {
            receiver.openExternalDocument(url)
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
    }
}
