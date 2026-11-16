import XCTest
import ChalkKit
@testable import Chalk

/// The shell's keys are the main menu's key equivalents, which AppKit routes
/// to the root through the responder chain from any first responder, the
/// palettes' search fields included. On Catalyst the same keys had to be
/// claimed as scene-level key commands (docs/issues/2026-08-17-fullscreen-drops-when-outline-opens.md);
/// here the menu is the one owner, and the palettes claim none of them.
@MainActor
final class ShellKeyEquivalentTests: XCTestCase {
    private func item(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem? {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.keyEquivalent == key, item.keyEquivalentModifierMask == modifiers { return item }
                if let submenu = item.submenu, let hit = find(submenu) { return hit }
            }
            return nil
        }
        return find(MainMenu.build())
    }

    func testTheMenuClaimsThePaletteAndPanelKeys() throws {
        XCTAssertEqual(try XCTUnwrap(item("o")).action, #selector(RootSplitViewController.cmdQuickOpen(_:)))
        XCTAssertEqual(try XCTUnwrap(item("p")).action, #selector(RootSplitViewController.cmdToggleOutline(_:)))
        XCTAssertEqual(try XCTUnwrap(item("k")).action, #selector(RootSplitViewController.cmdToggleOutlinePanel(_:)))
        XCTAssertEqual(try XCTUnwrap(item("j")).action, #selector(RootSplitViewController.cmdToggleSidebar(_:)))
        XCTAssertEqual(try XCTUnwrap(item("o", [.command, .shift])).action,
                       #selector(RootSplitViewController.cmdAddLocation(_:)))
    }

    func testTheMenuClaimsTheAiMarkKeys() throws {
        XCTAssertEqual(try XCTUnwrap(item("\r", [.command, .shift])).action,
                       #selector(RootSplitViewController.cmdAcceptAiMarks(_:)))
        XCTAssertEqual(try XCTUnwrap(item("\u{8}", [.command, .shift])).action,
                       #selector(RootSplitViewController.cmdRejectAiMarks(_:)))
    }

    /// The key the outline moved off (⌘;, 2026-08-26) must be free.
    func testTheMenuNoLongerClaimsCmdSemicolon() {
        XCTAssertNil(item(";"), "⌘; is no longer the outline key")
    }

    /// The palettes must NOT carry the toggle keys themselves: a permanently
    /// mounted child claiming ⌘P would shadow the shell.
    func testPalettesDoNotShadowTheToggleKeys() {
        let root = RootSplitViewController()
        root.loadViewIfNeeded()
        root.cmdToggleOutline()
        root.cmdQuickOpen()
        for child in root.children {
            for key in ["p", "k", "o"] {
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                    windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key,
                    isARepeat: false, keyCode: 0)!
                XCTAssertFalse(child.view.performKeyEquivalent(with: event),
                               "\(type(of: child)) must not claim ⌘\(key)")
            }
        }
    }

    /// A focused editor claims Ctrl+Tab before the menu; the page forwards it (`next-tab`,
    /// `previous-tab`) so the tabs still cycle.
    func testCtrlTabFromTheFocusedEditorCyclesTheTabs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chalk-ctrltab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = ["a.md", "b.md", "c.md"].map { dir.appendingPathComponent($0) }
        for url in urls { try "# x\n".write(to: url, atomically: true, encoding: .utf8) }
        let window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        defer { dismantleHostedSidebar(window) }
        let root = RootSplitViewController(initialContent: .openEmpty)
        root.motionPolicyForTesting = .instant
        window.rootViewController = root
        window.isHidden = false
        root.loadViewIfNeeded()
        let editor = root.editorForTesting
        for url in urls { editor.open(url: url) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 3))
        let web = try XCTUnwrap(editor.activeWebSurfaceForDebug?.webView)

        func press(_ characters: String, _ modifiers: NSEvent.ModifierFlags) {
            window.makeFirstResponder(editor.activeWebSurfaceForDebug?.webView ?? web)
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 48)!
            XCTAssertTrue(window.performKeyEquivalent(with: event), "the web view claims the key")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        }
        XCTAssertEqual(editor.activeTabIndexForTesting, 2)
        press("\t", .control)
        XCTAssertEqual(editor.activeTabIndexForTesting, 0, "Ctrl+Tab wraps to the first tab")
        press("\u{19}", [.control, .shift])
        XCTAssertEqual(editor.activeTabIndexForTesting, 2, "Ctrl+Shift+Tab wraps back")
    }
}
