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
}
