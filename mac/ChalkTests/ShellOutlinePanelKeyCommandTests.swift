import XCTest
@testable import Chalk

/// ⌘K is claimed at the scene level with system priority, for the same
/// reasons as ⌘P (see ShellOutlineKeyCommandTests), and no permanently
/// mounted child may shadow it.
@MainActor
final class ShellOutlinePanelKeyCommandTests: XCTestCase {
    private func makeRoot() -> RootSplitViewController {
        let root = RootSplitViewController()
        root.loadViewIfNeeded()
        return root
    }

    func testRootClaimsCmdKWithSystemPriority() {
        let cmd = makeRoot().keyCommands?.first { $0.input == "k" && $0.modifierFlags == .command }
        XCTAssertNotNil(cmd, "⌘K must be a scene-level key command")
        XCTAssertEqual(cmd?.action, #selector(RootSplitViewController.cmdToggleOutlinePanel))
        XCTAssertEqual(cmd?.wantsPriorityOverSystemBehavior, true)
    }

    func testChildrenDoNotShadowCmdK() {
        let root = makeRoot()
        root.cmdToggleOutline()
        root.cmdToggleOutlinePanel()
        for child in root.children {
            let hit = child.keyCommands?.contains { $0.input == "k" && $0.modifierFlags == .command }
            XCTAssertNotEqual(hit, true, "\(type(of: child)) must not claim ⌘K")
        }
    }
}
