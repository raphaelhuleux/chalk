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

    /// The app's one Settings window, made on first use and kept.
    private var settingsWindow: SettingsWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        recordLaunch()
        NSApp.mainMenu = MainMenu.build()
    }

    /// Runs before any window: constructing `AlphaSession` reads and clears
    /// the launch marker, which every later read depends on.
    private func recordLaunch() {
        let alpha = AlphaSession.shared
        let verdict: Int
        switch alpha.verdict {
        case .firstLaunch: verdict = 0
        case .clean: verdict = 1
        case .abnormal: verdict = 2
        }
        Diagnostics.record(.launch, a: verdict)
        // Corroboration only: a crash with no dirty buffers leaves no residue,
        // so it cannot stand in for the marker.
        let residue = RecoveryStore(directory: RecoveryStore.appDirectory).pendingCount()
        if residue > 0 { Diagnostics.record(.recoveryResidueFound, a: residue) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AlphaSession.shared.markForeground()
    }

    /// An orderly exit. Anything that leaves the marker armed was a death nobody handled.
    func applicationWillTerminate(_ notification: Notification) {
        AlphaSession.shared.markClean()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.log.notice("launched; opening the first window")
        let controller = openNewWindow()
        // The crash prompt, once the window is on screen and settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak controller] in
            controller?.root.presentAlphaNoticeIfNeeded()
        }
        #if DEBUG
        // A folder to show in the Library straight away, for screenshots
        // and manual checks before per-window Locations land (phase 6).
        if let path = ProcessInfo.processInfo.environment["CHALK_DEBUG_LIBRARY"], !path.isEmpty {
            controller.root.setLibraryLocationsForTesting([URL(fileURLWithPath: path)])
            controller.root.setSidebarVisible(true)
        }
        // A palette opened once the window is up, for the same purpose.
        if let palette = ProcessInfo.processInfo.environment["CHALK_DEBUG_PALETTE"], !palette.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                switch palette {
                case "quick-open": controller.root.cmdQuickOpen(nil)
                case "outline": controller.root.cmdToggleOutline(nil)
                case "outline-panel": controller.root.cmdToggleOutlinePanel(nil)
                case "settings": self.showSettings()
                case "settings-shortcuts":
                    self.showSettings()
                    self.settingsWindow?.container.selectRailForTesting(section: 1, row: 1)
                default: break
                }
            }
        }
        #endif
    }

    /// The app outlives its last window, like every Mac document app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @discardableResult
    func openNewWindow(initialContent: SceneConnectContent = .openWelcome) -> EditorWindowController {
        let controller = EditorWindowController(initialContent: initialContent)
        controller.onClose = { [weak self, weak controller] in
            self?.editorWindows.removeAll { $0 === controller }
        }
        editorWindows.append(controller)
        controller.showWindow(nil)
        Self.log.notice("window opened: visible=\(controller.window?.isVisible ?? false, privacy: .public) windows=\(self.editorWindows.count, privacy: .public)")
        return controller
    }

    @objc func cmdNewWindow(_ sender: Any?) { openNewWindow() }

    /// Focus the Settings window, making it only the first time: ⌘, must
    /// never stack Settings windows.
    func showSettings() {
        let controller = settingsWindow ?? SettingsWindowController()
        settingsWindow = controller
        #if DEBUG
        controller.container.openCommandTime = CACurrentMediaTime()
        #endif
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// On the delegate too: with no editor window, the app menu's item still
    /// resolves through the responder chain's end.
    @objc func cmdSettings(_ sender: Any?) { showSettings() }

    #if DEBUG
    var settingsWindowForTesting: SettingsWindowController? { settingsWindow }
    #endif
}
