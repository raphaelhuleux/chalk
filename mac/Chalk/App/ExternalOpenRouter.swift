import UIKit
import ChalkKit

/// Sends files and folders handed to the app from outside (Finder, Raycast "Open With",
/// `open -a Chalk <path>`) to the right window, VS Code style. The OS delivers to a scene of its
/// choosing; this decides where each URL goes. The rules live in `ExternalOpenRouting`.
enum ExternalOpenRouter {
    static func route(_ urls: [URL], receivedBy receiver: RootSplitViewController) {
        for url in urls { route(url, receivedBy: receiver) }
    }

    private static func route(_ url: URL, receivedBy receiver: RootSplitViewController) {
        // The directory check and the bookmark below both need the sender's scope in the sandbox.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let windows = editorWindows()
        let roots = windows.map { $0.root.libraryRoots.map(\.fileIdentity) }

        if isDirectory(url) {
            if let index = ExternalOpenRouting.windowShowing(folder: url.fileIdentity, windowRoots: roots) {
                bringForward(windows[index].scene)
            } else if receiver.isPristine {
                receiver.addFolderToWindow(url)
            } else if let bookmark = FileBookmark.make(for: url) {
                let activity = NSUserActivity(activityType: ChalkActivity.newWindowType)
                activity.userInfo = [ChalkActivity.folderBookmarkKey: bookmark]
                UIApplication.shared.requestSceneSessionActivation(
                    nil, userActivity: activity, options: nil)
            } else {
                receiver.addFolderToWindow(url)
            }
            return
        }

        if let index = ExternalOpenRouting.windowContaining(file: url.fileIdentity, windowRoots: roots),
           windows[index].root !== receiver {
            windows[index].root.openExternalDocument(url)
            bringForward(windows[index].scene)
        } else {
            receiver.openExternalDocument(url)
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
    }

    private static func bringForward(_ scene: UIWindowScene) {
        UIApplication.shared.requestSceneSessionActivation(
            scene.session, userActivity: nil, options: nil)
    }

    /// Editor windows, frontmost first (the active one, then other visible ones), so ties go to the
    /// window the user is looking at.
    private static func editorWindows() -> [(scene: UIWindowScene, root: RootSplitViewController)] {
        func rank(_ state: UIScene.ActivationState) -> Int {
            switch state {
            case .foregroundActive: return 0
            case .foregroundInactive: return 1
            default: return 2
            }
        }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
            .compactMap { scene in
                scene.windows.lazy.compactMap { $0.rootViewController as? RootSplitViewController }
                    .first.map { (scene, $0) }
            }
            .sorted { rank($0.scene.activationState) < rank($1.scene.activationState) }
    }
}
