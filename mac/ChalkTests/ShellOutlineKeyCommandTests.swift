import XCTest
@testable import Chalk

/// The scene-level outline key command — the 2026-08-17 full-screen-drop fix.
///
/// The key is ⌘P since 2026-08-26 (it was ⌘;, which doubled as a second,
/// undocumented way into Quick Open — that is ⌘O alone now).
///
/// With a native text field focused (outline/Quick Open search, sidebar
/// rename), Catalyst routes a raw ⌘-key keyDown into AppKit's text-input
/// funnel (`UINSInputView.doCommandBySelector:`). A key command on the root
/// controller with `wantsPriorityOverSystemBehavior` claims the press in
/// UIKit's key-command phase, which runs before that funnel, from ANY first
/// responder in the scene — which is what this pins.
///
/// The original ⌘; carried an extra hazard the move retires: on layouts where
/// "." shares the ";" key (French AZERTY) the system read it as the cancel key
/// ⌘., and `NSWindow`'s default for cancel in full screen is EXIT FULL SCREEN
/// (stack-verified live).
///
/// Do NOT move this onto the palette view controllers: they are mounted
/// permanently, so their `keyCommands` are live even while hidden — that
/// shadowed the shell and broke opening entirely once before (the reverted
/// "attempt 2" in docs/issues/2026-08-17-fullscreen-drops-when-outline-opens.md).
/// Toggle semantics on the root are state-correct from everywhere.
@MainActor
final class ShellOutlineKeyCommandTests: XCTestCase {
    private func makeRoot() -> RootSplitViewController {
        let root = RootSplitViewController()
        root.loadViewIfNeeded()
        return root
    }

    func testRootClaimsCmdPWithSystemPriority() {
        let cmd = makeRoot().keyCommands?.first {
            $0.input == "p" && $0.modifierFlags == .command
        }
        XCTAssertNotNil(cmd, "⌘P must be a scene-level key command")
        XCTAssertEqual(cmd?.action, #selector(RootSplitViewController.cmdToggleOutline))
        XCTAssertEqual(cmd?.wantsPriorityOverSystemBehavior, true,
                       "without priority the text-input funnel still wins")
    }

    /// And the key it moved off must be free.
    func testRootNoLongerClaimsCmdSemicolon() {
        let cmd = makeRoot().keyCommands?.first {
            $0.input == ";" && $0.modifierFlags == .command
        }
        XCTAssertNil(cmd, "⌘; is no longer the outline key")
    }

    /// The palettes must NOT carry their own toggle key — the attempt-2 regression.
    func testPalettesDoNotShadowTheToggleKey() {
        let root = makeRoot()
        root.cmdToggleOutline() // mounts the palette child VCs
        for child in root.children {
            let hit = child.keyCommands?.contains {
                $0.input == "p" && $0.modifierFlags == .command
            }
            XCTAssertNotEqual(hit, true,
                              "\(type(of: child)) must not claim ⌘; (see attempt 2)")
        }
    }
}
