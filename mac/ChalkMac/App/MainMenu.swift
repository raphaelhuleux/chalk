import AppKit

/// The main menu, built in code. It carries what the shipped phases need
/// (Quit, Close, New Window, the Library's two commands); the full menu from
/// the plan's "Menu bar" section lands in phase 6.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Settings\u{2026}", action: #selector(RootSplitViewController.cmdSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Chalk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: ""))

        let file = NSMenu(title: "File")
        let newWindow = file.addItem(withTitle: "New Window", action: #selector(AppDelegate.cmdNewWindow(_:)), keyEquivalent: "n")
        newWindow.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Quick Open\u{2026}",
                     action: #selector(RootSplitViewController.cmdQuickOpen(_:)), keyEquivalent: "o")
        let addFolder = file.addItem(withTitle: "Add Folder to Window\u{2026}",
                                     action: #selector(RootSplitViewController.cmdAddLocation(_:)), keyEquivalent: "o")
        addFolder.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(file, title: "File"))

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Toggle Library", action: #selector(RootSplitViewController.cmdToggleSidebar(_:)), keyEquivalent: "j")
        view.addItem(withTitle: "Outline", action: #selector(RootSplitViewController.cmdToggleOutline(_:)), keyEquivalent: "p")
        view.addItem(withTitle: "Outline Panel", action: #selector(RootSplitViewController.cmdToggleOutlinePanel(_:)), keyEquivalent: "k")
        main.addItem(submenu(view, title: "View"))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        for item in helpMenuItems() { help.addItem(item) }
        main.addItem(submenu(help, title: "Help"))
        NSApp.helpMenu = help

        return main
    }

    /// What the Help menu offers; `HelpMenuTests` reads it.
    static func helpMenuItems() -> [NSMenuItem] {
        [
            NSMenuItem(title: "Report a Problem\u{2026}",
                       action: #selector(RootSplitViewController.cmdReportProblem(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Privacy",
                       action: #selector(RootSplitViewController.cmdPrivacy(_:)), keyEquivalent: ""),
        ]
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
