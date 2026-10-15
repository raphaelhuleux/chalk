import AppKit
import ChalkKit

/// The AppKit shell's application delegate. Owns the editor windows for their
/// lifetime (AppKit does not retain window controllers) and the main menu.
/// Growing per docs/specs/2026-10-15-appkit-shell-rewrite-plan.md.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Every live editor window. A controller leaves when its window closes.
    private(set) var editorWindows: [EditorWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        openNewWindow()
    }

    /// The app outlives its last window, like every Mac document app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @discardableResult
    func openNewWindow() -> EditorWindowController {
        let controller = EditorWindowController()
        controller.onClose = { [weak self, weak controller] in
            self?.editorWindows.removeAll { $0 === controller }
        }
        editorWindows.append(controller)
        controller.showWindow(nil)
        return controller
    }

    @objc func cmdNewWindow(_ sender: Any?) { openNewWindow() }
}
