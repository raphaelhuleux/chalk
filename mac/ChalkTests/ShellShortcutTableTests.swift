import XCTest
import ChalkKit
@testable import Chalk

/// The `pressesBegan` shortcut table (`WebEditorSurface`), which is the lane a
/// keystroke takes when the focused WKWebView would otherwise eat it.
///
/// Written because ⌘O — the Quick Open shortcut the design promised — was
/// bound in NONE of the app's three delivery lanes for the project's whole
/// life. The palette was complete and reachable on ⌘P; nothing failed loudly,
/// the key simply did nothing. Owner-reported 2026-08-17.
@MainActor
final class ShellShortcutTableTests: XCTestCase {
    private func action(_ chars: String, shift: Bool = false,
                        control: Bool = false, isTab: Bool = false) -> Selector? {
        EditorWebView.shellAction(chars: chars, isTab: isTab,
                                  command: !control, shift: shift, control: control)
    }

    // MARK: - Quick Open

    func testCommandOOpensQuickOpen() {
        XCTAssertEqual(action("o"), #selector(RootSplitViewController.cmdQuickOpen))
    }

    /// ⌘P is NOT a second way into Quick Open. It was an undocumented alias
    /// until 2026-08-26, which made the palette answer to two keys while the
    /// outline answered to a third; ⌘O opens Quick Open and ⌘P opens the
    /// outline (owner request).
    func testCommandPDoesNotOpenQuickOpen() {
        XCTAssertNotEqual(action("p"), #selector(RootSplitViewController.cmdQuickOpen))
    }

    // MARK: - Outline

    /// ⌘P, not ⌘; — which also retires the AZERTY hazard that key carried
    /// (there "." shares the ";" key, so the input context read ⌘; as ⌘. and
    /// exited full screen).
    func testCommandPTogglesTheOutline() {
        XCTAssertEqual(action("p"), #selector(RootSplitViewController.cmdToggleOutline))
    }

    func testCommandSemicolonNoLongerTogglesTheOutline() {
        XCTAssertNotEqual(action(";"), #selector(RootSplitViewController.cmdToggleOutline))
    }

    func testCommandKTogglesTheOutlinePanel() {
        XCTAssertEqual(action("k"), #selector(RootSplitViewController.cmdToggleOutlinePanel))
    }

    /// ⇧⌘O is "Add Folder to Window…" and must not be swallowed by the new ⌘O.
    func testShiftCommandOStillAddsALocation() {
        XCTAssertEqual(action("o", shift: true),
                       #selector(RootSplitViewController.cmdAddLocation))
    }

    // MARK: - The rest of the table is undisturbed

    func testOtherShortcutsAreUnchanged() {
        XCTAssertEqual(action("n"), #selector(RootSplitViewController.cmdNewFile))
        XCTAssertEqual(action("s"), #selector(RootSplitViewController.cmdSave))
        XCTAssertEqual(action("w"), #selector(RootSplitViewController.cmdCloseTab))
        XCTAssertEqual(action("j"), #selector(RootSplitViewController.cmdToggleSidebar))
        XCTAssertEqual(action(","), #selector(RootSplitViewController.cmdSettings))
        XCTAssertEqual(action("m", shift: true),
                       #selector(RootSplitViewController.cmdCycleEditingMode))
    }

    func testControlTabCyclesTabs() {
        XCTAssertEqual(action("\t", control: true, isTab: true),
                       #selector(RootSplitViewController.cmdNextTab))
        XCTAssertEqual(action("\t", shift: true, control: true, isTab: true),
                       #selector(RootSplitViewController.cmdPrevTab))
    }

    /// Plain typing must fall straight through to the web view.
    func testUnmodifiedKeysAreNotClaimed() {
        XCTAssertNil(EditorWebView.shellAction(
            chars: "o", isTab: false, command: false, shift: false, control: false))
        XCTAssertNil(EditorWebView.shellAction(
            chars: "a", isTab: false, command: false, shift: false, control: false))
    }

    func testUnboundCommandKeysAreNotClaimed() {
        XCTAssertNil(action("q"))
        XCTAssertNil(action("z"))
    }
}
