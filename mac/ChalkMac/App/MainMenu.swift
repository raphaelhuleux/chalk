import AppKit

/// The main menu, built in code. Phase 0 carries only what keeps the app
/// usable (Quit, Close, New Window); the full menu from the plan's "Menu bar"
/// section lands in phase 6.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Quit Chalk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: ""))

        let file = NSMenu(title: "File")
        let newWindow = file.addItem(withTitle: "New Window", action: #selector(AppDelegate.cmdNewWindow(_:)), keyEquivalent: "n")
        newWindow.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(file, title: "File"))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
