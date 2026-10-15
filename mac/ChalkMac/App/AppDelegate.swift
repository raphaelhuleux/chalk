import AppKit
import ChalkKit
import os

/// The AppKit shell's application delegate. Owns the editor windows for their
/// lifetime (AppKit does not retain window controllers) and the main menu.
/// Attached in main.swift, not through `@main`: with `@main` on this class the
/// delegate was never attached and the app sat in its run loop with no window.
/// Growing per docs/specs/2026-10-15-appkit-shell-rewrite-plan.md.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Every live editor window. A controller leaves when its window closes.
    private(set) var editorWindows: [EditorWindowController] = []

    /// Launch and window breadcrumbs, notice level so `log show` keeps them
    /// without `--info`. Read with:
    ///   log show --last 5m --predicate 'subsystem == "com.huleux.chalk"'
    private static let log = Logger(subsystem: "com.huleux.chalk", category: "app")

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.log.notice("launched; opening the first window")
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
        Self.log.notice("window opened: visible=\(controller.window?.isVisible ?? false, privacy: .public) windows=\(self.editorWindows.count, privacy: .public)")
        return controller
    }

    @objc func cmdNewWindow(_ sender: Any?) { openNewWindow() }
}
