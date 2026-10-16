import AppKit

/// The main menu, built in code. Every shell command is a nil-target action, so it reaches the
/// key window's root through the responder chain and greys out when no
/// editor window is key; New Window and Settings also live on the app
/// delegate, so they stay enabled with no window open. No Format menu (⌘B is
/// the editor's), no Spelling submenu, no system Close/Duplicate/Rename.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Settings\u{2026}", action: #selector(RootSplitViewController.cmdSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Chalk", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Chalk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: ""))

        let file = NSMenu(title: "File")
        let newWindow = file.addItem(withTitle: "New Window", action: #selector(AppDelegate.cmdNewWindow(_:)), keyEquivalent: "n")
        newWindow.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: "New", action: #selector(RootSplitViewController.cmdNewFile(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "Quick Open\u{2026}",
                     action: #selector(RootSplitViewController.cmdQuickOpen(_:)), keyEquivalent: "o")
        let addFolder = file.addItem(withTitle: "Add Folder to Window\u{2026}",
                                     action: #selector(RootSplitViewController.cmdAddLocation(_:)), keyEquivalent: "o")
        addFolder.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: "Save", action: #selector(RootSplitViewController.cmdSave(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "Close Tab", action: #selector(RootSplitViewController.cmdCloseTab(_:)), keyEquivalent: "w")
        main.addItem(submenu(file, title: "File"))

        // The standard editing actions, which the web view answers; without
        // them ⌘Z, ⌘C and ⌘V have no key equivalent to route through.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Toggle Sidebar", action: #selector(RootSplitViewController.cmdToggleSidebar(_:)), keyEquivalent: "j")
        view.addItem(withTitle: "Outline", action: #selector(RootSplitViewController.cmdToggleOutline(_:)), keyEquivalent: "p")
        view.addItem(withTitle: "Outline Panel", action: #selector(RootSplitViewController.cmdToggleOutlinePanel(_:)), keyEquivalent: "k")
        view.addItem(.separator())
        view.addItem(submenu(editingModeMenu(), title: "Editing Mode"))
        view.addItem(submenu(viewModeMenu(), title: "View Mode"))
        view.addItem(.separator())
        view.addItem(withTitle: "Zoom In", action: #selector(RootSplitViewController.cmdZoomIn(_:)), keyEquivalent: "=")
        view.addItem(withTitle: "Zoom Out", action: #selector(RootSplitViewController.cmdZoomOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(RootSplitViewController.cmdZoomReset(_:)), keyEquivalent: "0")
        view.addItem(.separator())
        let nextTab = view.addItem(withTitle: "Next Tab", action: #selector(RootSplitViewController.cmdNextTab(_:)), keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        let previousTab = view.addItem(withTitle: "Previous Tab", action: #selector(RootSplitViewController.cmdPrevTab(_:)), keyEquivalent: "\t")
        previousTab.keyEquivalentModifierMask = [.control, .shift]
        main.addItem(submenu(view, title: "View"))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        for item in helpMenuItems() { help.addItem(item) }
        main.addItem(submenu(help, title: "Help"))
        NSApp.helpMenu = help

        return main
    }

    /// Editing modes: the submenu picks directly (the active one is checked
    /// by `RootSplitViewController.validateMenuItem`); one shortcut cycles.
    static func editingModeMenu() -> NSMenu {
        let menu = NSMenu(title: "Editing Mode")
        menu.addItem(withTitle: "Normal", action: #selector(RootSplitViewController.cmdEditingModeNormal(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Zen", action: #selector(RootSplitViewController.cmdEditingModeZen(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Typewriter", action: #selector(RootSplitViewController.cmdEditingModeTypewriter(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Focus", action: #selector(RootSplitViewController.cmdEditingModeFocus(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let cycle = menu.addItem(withTitle: "Cycle Editing Mode", action: #selector(RootSplitViewController.cmdCycleEditingMode(_:)), keyEquivalent: "m")
        cycle.keyEquivalentModifierMask = [.command, .shift]
        return menu
    }

    /// Default view mode: the three picks set the default every editor opens
    /// in. No cycle item on purpose: ⌘: inside the editor cycles ONE editor,
    /// and a host cycle would move the default instead.
    static func viewModeMenu() -> NSMenu {
        let menu = NSMenu(title: "View Mode")
        menu.addItem(withTitle: "Preview", action: #selector(RootSplitViewController.cmdViewModePreview(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Mixed", action: #selector(RootSplitViewController.cmdViewModeMixed(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Source", action: #selector(RootSplitViewController.cmdViewModeSource(_:)), keyEquivalent: "")
        return menu
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
