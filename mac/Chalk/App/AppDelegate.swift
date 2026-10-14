import UIKit
import os
import ChalkKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        recordLaunch()
        return true
    }

    /// Runs before any scene connects, which both reads need: constructing
    /// `AlphaSession` clears the launch marker, and SceneDelegate drains the
    /// recovery store on the first connect.
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

    /// An orderly exit. Pairs with the scene hooks: between them, anything that
    /// leaves the marker armed was a death nobody handled.
    func applicationWillTerminate(_ application: UIApplication) {
        AlphaSession.shared.markClean()
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let role = SceneRouting.role(
            sessionRole: connectingSceneSession.role,
            activityTypes: options.userActivities.map(\.activityType),
            restorationType: connectingSceneSession.stateRestorationActivity?.activityType)

        // A role the app does not support (see DeclinedSceneDelegate): connect
        // it with no window and destroy it.
        if role == .declined {
            let config = UISceneConfiguration(
                name: "Declined Configuration", sessionRole: connectingSceneSession.role)
            config.delegateClass = DeclinedSceneDelegate.self
            return config
        }

        if role == .settings {
            let config = UISceneConfiguration(
                name: "Settings Configuration", sessionRole: connectingSceneSession.role)
            config.delegateClass = SettingsSceneDelegate.self
            return config
        }

        let config = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        config.delegateClass = SceneDelegate.self
        return config
    }

    /// Logs the sessions the OS actually dropped after the settle sweep (or
    /// Cmd+W on an empty window) asked it to destroy them.
    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {
        Logger(subsystem: "com.huleux.chalk", category: "scene")
            .info("OS discarded \(sceneSessions.count) scene session(s)")
        WindowLocations.discard(windows: sceneSessions.map(\.persistentIdentifier))
    }

    // MARK: - Shell commands with app-level scope

    /// On the AppDelegate because on Mac the app outlives its last window: with
    /// no split VC in the responder chain a nil-target selector would leave the
    /// menu item disabled. The responder chain always ends at the delegate.
    @objc func cmdNewWindow() {
        let activity = NSUserActivity(activityType: ChalkActivity.newWindowType)
        UIApplication.shared.requestSceneSessionActivation(
            nil, userActivity: activity, options: nil)
    }

    // MARK: - Menu bar

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }

        func key(_ title: String, _ action: Selector, _ input: String,
                 _ flags: UIKeyModifierFlags = .command) -> UIKeyCommand {
            UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags)
        }

        // The system File menu carries document items (Duplicate=Cmd+S, Close=
        // Cmd+W, Move/Rename/Export) that shadow our shortcuts, and inserting into
        // it is unreliable on Catalyst. Replace it wholesale with a clean File
        // menu, and drop other colliding standards (Bold/Cmd+B, Toolbar).
        builder.remove(menu: .file)
        builder.remove(menu: .format)
        builder.remove(menu: .toolbar)
        // Catalyst auto-adds Show/Hide Sidebar, routed through the animated
        // `toggleSidebar:`, which flickers. Cmd+J (cmdToggleSidebar) is the
        // only sidebar toggle.
        builder.remove(menu: .sidebar)
        // Catalyst silently drops an app menu item whose key equivalent
        // collides with a system one, and Check Document Now takes Cmd+;. The
        // webview editor never used the system spelling suite.
        builder.remove(menu: .spelling)

        let fileMenu = UIMenu(title: "File", children: [
            UIMenu(title: "", options: .displayInline, children: [
                key("New Window", #selector(AppDelegate.cmdNewWindow), "n", [.command, .shift]),
            ]),
            UIMenu(title: "", options: .displayInline, children: [
                key("New", #selector(RootSplitViewController.cmdNewFile), "n"),
                // Removing the system File menu above leaves Cmd+O free for
                // Quick Open.
                key("Quick Open\u{2026}", #selector(RootSplitViewController.cmdQuickOpen), "o"),
                key("Add Folder to Window\u{2026}", #selector(RootSplitViewController.cmdAddLocation), "o", [.command, .shift]),
            ]),
            UIMenu(title: "", options: .displayInline, children: [
                key("Save", #selector(RootSplitViewController.cmdSave), "s"),
                key("Close Tab", #selector(RootSplitViewController.cmdCloseTab), "w"),
            ]),
        ])
        builder.insertSibling(fileMenu, afterMenu: .application)

        builder.insertChild(
            UIMenu(title: "", options: .displayInline, children: [
                key("Settings\u{2026}", #selector(RootSplitViewController.cmdSettings), ","),
            ]),
            atStartOfMenu: .application)

        // Editing modes: one shortcut cycles; the submenu picks directly (the
        // active mode gets a checkmark via RootSplitViewController.validate).
        let modeMenu = UIMenu(title: "Editing Mode", children: [
            UIMenu(title: "", options: .displayInline, children: [
                UICommand(title: "Normal", action: #selector(RootSplitViewController.cmdEditingModeNormal)),
                UICommand(title: "Zen", action: #selector(RootSplitViewController.cmdEditingModeZen)),
                UICommand(title: "Typewriter", action: #selector(RootSplitViewController.cmdEditingModeTypewriter)),
                UICommand(title: "Focus", action: #selector(RootSplitViewController.cmdEditingModeFocus)),
            ]),
            UIMenu(title: "", options: .displayInline, children: [
                key("Cycle Editing Mode", #selector(RootSplitViewController.cmdCycleEditingMode), "m", [.command, .shift]),
            ]),
        ])

        // Default view mode: the three picks set the default every editor
        // opens in. No cycle item here on purpose: Cmd+: (inside the editor)
        // cycles ONE editor, and a host cycle would move the default instead.
        let viewModeMenu = UIMenu(title: "View Mode", children: [
            UICommand(title: "Preview", action: #selector(RootSplitViewController.cmdViewModePreview)),
            UICommand(title: "Mixed", action: #selector(RootSplitViewController.cmdViewModeMixed)),
            UICommand(title: "Source", action: #selector(RootSplitViewController.cmdViewModeSource)),
        ])

        let viewGroup = UIMenu(title: "", options: .displayInline, children: [
            key("Toggle Sidebar", #selector(RootSplitViewController.cmdToggleSidebar), "j"),
            key("Outline", #selector(RootSplitViewController.cmdToggleOutline), "p"),
            key("Outline Panel", #selector(RootSplitViewController.cmdToggleOutlinePanel), "k"),
            modeMenu,
            viewModeMenu,
            key("Zoom In", #selector(RootSplitViewController.cmdZoomIn), "="),
            key("Zoom Out", #selector(RootSplitViewController.cmdZoomOut), "-"),
            key("Actual Size", #selector(RootSplitViewController.cmdZoomReset), "0"),
            key("Next Tab", #selector(RootSplitViewController.cmdNextTab), "\t", .control),
            key("Previous Tab", #selector(RootSplitViewController.cmdPrevTab), "\t", [.control, .shift]),
        ])
        if builder.menu(for: .view) != nil {
            builder.insertChild(viewGroup, atStartOfMenu: .view)
        } else {
            builder.insertSibling(UIMenu(title: "View", children: [viewGroup]), afterMenu: .edit)
        }

        buildHelpMenu(with: builder)
    }

    /// Split out from `buildHelpMenu` so `HelpMenuTests` can read it:
    /// `UIMenuBuilder` cannot be constructed in a test.
    static func helpMenuItems() -> [UICommand] {
        [
            UICommand(title: "Report a Problem\u{2026}",
                      action: #selector(RootSplitViewController.cmdReportProblem)),
            UICommand(title: "Privacy",
                      action: #selector(RootSplitViewController.cmdPrivacy)),
        ]
    }

    /// Catalyst vends a `.help` menu only under some conditions, so this
    /// inserts into it or creates one.
    private func buildHelpMenu(with builder: UIMenuBuilder) {
        let items = UIMenu(
            title: "", options: .displayInline,
            children: Self.helpMenuItems())
        if builder.menu(for: .help) != nil {
            builder.insertChild(items, atStartOfMenu: .help)
        } else {
            builder.insertSibling(UIMenu(title: "Help", children: [items]), afterMenu: .window)
        }
    }
}
