import XCTest
import ChalkKit
@testable import Chalk

/// The main menu is the Catalyst shell's menu, and its shell commands act on
/// the key window: every item is a nil-target action, so the responder chain
/// picks the key window's root and no other. This replaces the Catalyst
/// `ShellShortcutTableTests` and the identity-routing half of
/// `WindowRoutingTests`, which existed because UIKit's key flag lied.
@MainActor
final class MenuRoutingTests: XCTestCase {
    private var controllers: [EditorWindowController] = []
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for controller in controllers { controller.close() }
        controllers = []
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func submenu(titled title: String, in main: NSMenu) throws -> NSMenu {
        try XCTUnwrap(main.items.first { $0.submenu?.title == title }?.submenu, "no \(title) menu")
    }

    private func itemTitles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
    }

    // MARK: - The menu itself

    func testTheMenuIsTheCatalystMenu() throws {
        let main = MainMenu.build()
        XCTAssertEqual(main.items.map { $0.submenu?.title ?? "" }, ["", "File", "Edit", "View", "Typeset", "Window", "Help"])

        let file = try submenu(titled: "File", in: main)
        XCTAssertEqual(itemTitles(file), ["New Window", "New", "Quick Open\u{2026}", "Add Folder to Window\u{2026}", "Save", "Close Tab"])
        XCTAssertNil(file.items.first { $0.title == "Close" }, "the system Close item would shadow Close Tab on ⌘W")

        let view = try submenu(titled: "View", in: main)
        XCTAssertEqual(itemTitles(view), ["Toggle Sidebar", "Outline", "Outline Panel", "Editing Mode", "View Mode",
                                      "Zoom In", "Zoom Out", "Actual Size", "Next Tab", "Previous Tab",
                                      "Split Editor", "Focus Other Pane"])
        let modes = try XCTUnwrap(view.items.first { $0.title == "Editing Mode" }?.submenu)
        XCTAssertEqual(itemTitles(modes), ["Normal", "Zen", "Typewriter", "Focus", "Cycle Editing Mode"])
        let viewModes = try XCTUnwrap(view.items.first { $0.title == "View Mode" }?.submenu)
        XCTAssertEqual(itemTitles(viewModes), ["Preview", "Mixed", "Source"])
        XCTAssertEqual(itemTitles(try submenu(titled: "Typeset", in: main)), ["Compile", "PDF Panel", "Show in PDF"])

        XCTAssertNil(main.items.first { $0.submenu?.title == "Format" }, "⌘B stays free for the editor")
        let app = try XCTUnwrap(main.items.first?.submenu)
        XCTAssertNil(app.items.first { $0.title.contains("Spelling") })
    }

    func testTheKeyEquivalentsMatchTheCatalystShell() throws {
        let main = MainMenu.build()
        func item(_ title: String) throws -> NSMenuItem {
            func find(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if item.title == title { return item }
                    if let submenu = item.submenu, let hit = find(submenu) { return hit }
                }
                return nil
            }
            return try XCTUnwrap(find(main), "no item \(title)")
        }
        XCTAssertEqual(try item("New Window").keyEquivalent, "n")
        XCTAssertEqual(try item("New Window").keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(try item("New").keyEquivalent, "n")
        XCTAssertEqual(try item("New").keyEquivalentModifierMask, [.command])
        XCTAssertEqual(try item("Save").keyEquivalent, "s")
        XCTAssertEqual(try item("Close Tab").keyEquivalent, "w")
        XCTAssertEqual(try item("Cycle Editing Mode").keyEquivalent, "m")
        XCTAssertEqual(try item("Cycle Editing Mode").keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(try item("Zoom In").keyEquivalent, "=")
        let view = try submenu(titled: "View", in: main)
        let zoomInPlus = try XCTUnwrap(view.items.first { $0.isHidden && $0.title == "Zoom In" }, "no hidden ⌘+ item")
        XCTAssertEqual(zoomInPlus.keyEquivalent, "+")
        XCTAssertEqual(zoomInPlus.action, #selector(RootSplitViewController.cmdZoomIn(_:)))
        XCTAssertTrue(zoomInPlus.allowsKeyEquivalentWhenHidden, "a hidden item's chord is dead without this")
        XCTAssertEqual(try item("Zoom Out").keyEquivalent, "-")
        XCTAssertEqual(try item("Actual Size").keyEquivalent, "0")
        XCTAssertEqual(try item("Next Tab").keyEquivalent, "\t")
        XCTAssertEqual(try item("Next Tab").keyEquivalentModifierMask, [.control])
        XCTAssertEqual(try item("Previous Tab").keyEquivalentModifierMask, [.control, .shift])
        XCTAssertEqual(try item("Split Editor").keyEquivalent, "\\")
        XCTAssertEqual(try item("Split Editor").keyEquivalentModifierMask, [.command])
        XCTAssertEqual(try item("Focus Other Pane").keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(try item("Settings\u{2026}").keyEquivalent, ",")
        XCTAssertEqual(try item("Compile").keyEquivalent, "r")
        XCTAssertEqual(try item("Compile").keyEquivalentModifierMask, [.command])
        XCTAssertEqual(try item("PDF Panel").keyEquivalent, "p")
        XCTAssertEqual(try item("PDF Panel").keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(try item("Show in PDF").keyEquivalent, "j")
        XCTAssertEqual(try item("Show in PDF").keyEquivalentModifierMask, [.command, .option])
    }

    /// A target would pin an item to one window; nil lets the responder chain
    /// pick the key window, and greys the item out when no editor is key.
    func testShellItemsHaveNoTarget() {
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                // AppKit points a submenu item's target at the submenu itself.
                if item.action != nil, item.submenu == nil {
                    XCTAssertNil(item.target, "\(item.title) is pinned to a target")
                }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(MainMenu.build())
    }

    /// New Window and Settings are on the app delegate, so they resolve with
    /// no editor window open.
    func testNewWindowAndSettingsResolveOnTheDelegate() {
        XCTAssertTrue(AppDelegate.instancesRespond(to: #selector(AppDelegate.cmdNewWindow(_:))))
        XCTAssertTrue(AppDelegate.instancesRespond(to: #selector(AppDelegate.cmdSettings(_:))))
    }

    // MARK: - Validation

    func testTheActiveEditingModeAndDefaultViewModeAreChecked() throws {
        let root = RootSplitViewController(initialContent: .openEmpty)
        root.loadViewIfNeeded()
        let incomingMode = Preferences.editingMode
        let incomingView = Preferences.viewMode
        defer {
            Preferences.editingMode = incomingMode
            Preferences.viewMode = incomingView
        }
        let modes = MainMenu.editingModeMenu()
        let zen = try XCTUnwrap(modes.items.first { $0.title == "Zen" })
        let normal = try XCTUnwrap(modes.items.first { $0.title == "Normal" })
        root.setEditingMode(.zen)
        XCTAssertTrue(root.validateMenuItem(zen))
        XCTAssertTrue(root.validateMenuItem(normal))
        XCTAssertEqual(zen.state, .on)
        XCTAssertEqual(normal.state, .off)

        let viewModes = MainMenu.viewModeMenu()
        let source = try XCTUnwrap(viewModes.items.first { $0.title == "Source" })
        Preferences.viewMode = .source
        XCTAssertTrue(root.validateMenuItem(source))
        XCTAssertEqual(source.state, .on)
    }

    // MARK: - The key window

    /// Two windows: a shell action sent up one window's responder chain
    /// reaches that window's root and no other. The Catalyst shell's stale
    /// key flag once sent Cmd+S to the wrong window (three silent presses).
    func testAMenuActionReachesOneWindowsRootOnly() throws {
        let a = EditorWindowController(initialContent: .openEmpty)
        let b = EditorWindowController(initialContent: .openEmpty)
        controllers = [a, b]
        a.showWindow(nil)
        b.showWindow(nil)
        let action = #selector(RootSplitViewController.cmdNewFile(_:))

        // The chain the menu walks from a key window's first responder: the
        // content view, its view controller (the root), the window.
        let contentB = try XCTUnwrap(b.window?.contentView)
        XCTAssertTrue(contentB.tryToPerform(action, with: nil), "the chain must reach a root")
        XCTAssertEqual(b.root.openTabCount, 1, "that window's root took the action")
        XCTAssertEqual(a.root.openTabCount, 0, "the other window's root did not")

        // With the test host active, the real dispatch (nil target, key
        // window) agrees. Not every runner lets the host become active.
        NSApp.activate(ignoringOtherApps: true)
        a.window?.makeKeyAndOrderFront(nil)
        if NSApp.keyWindow === a.window {
            XCTAssertTrue(NSApp.sendAction(action, to: nil, from: nil))
            XCTAssertEqual(a.root.openTabCount, 1)
            XCTAssertEqual(b.root.openTabCount, 1)
        }
    }
}
