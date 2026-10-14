import XCTest
import ChalkKit
@testable import Chalk

/// Keyboard navigation for the Library tree (bug 2026-08-02): arrow keys move
/// UIKit focus but the row painter only styled `isSelected`, so keyboard users
/// got the system focus halo instead of the design's Ink pill.
///
/// Contract under test:
/// - Return / keypad-Enter are deliberately UNCLAIMED (decision 2026-08-15:
///   the sidebar must never eat the editor's Return on Catalyst); keyboard
///   activation is the focus system's Space, through the shared activate()
///   path (folders toggle, files open, the "Empty" sentinel is inert).
/// - Left/Right fold/unfold a focused folder, Finder-style; F2 renames.
/// - Up/Down stay with the focus system (no UIKeyCommand claims them).
/// - Focused rows paint the selection pill; the system halo is suppressed.
/// - The "Empty" sentinel row can't take focus at all.
@MainActor
final class SidebarKeyboardNavTests: XCTestCase {
    private var window: UIWindow!
    private var host: UIViewController!
    private var sidebar: SidebarViewController!
    private var root: URL!
    private var emptyRoot: URL!

    private var collectionView: UICollectionView { sidebar.collectionViewForTesting }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Root/
        //   Papers/draft.tex
        //   index.md
        // Empty/            (second Location, renders the "Empty" sentinel row)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-keynav-\(UUID().uuidString)")
        let papers = root.appendingPathComponent("Papers")
        try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
        try "x".write(to: papers.appendingPathComponent("draft.tex"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-keynav-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)

        sidebar = SidebarViewController()
        sidebar.locationsProvider = { [
            Location(id: "main", name: "Root", url: self.root),
            Location(id: "empty", name: "Empty", url: self.emptyRoot),
        ] }
        host = UIViewController()
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first!
        window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        host.addChild(sidebar)
        sidebar.view.translatesAutoresizingMaskIntoConstraints = true
        sidebar.view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        host.view.addSubview(sidebar.view)
        sidebar.didMove(toParent: host)
        sidebar.reload()
        window.layoutIfNeeded()
        collectionView.layoutIfNeeded()
    }

    override func tearDownWithError() throws {
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        host = nil
        sidebar = nil
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: emptyRoot)
        try super.tearDownWithError()
    }

    private func folderNode() throws -> FileNode {
        try XCTUnwrap(FileTree.children(of: root).first(where: \.isDirectory))
    }

    private func fileNode() throws -> FileNode {
        try XCTUnwrap(FileTree.children(of: root).first { !$0.isDirectory })
    }

    // MARK: Key commands

    func testKeyCommandsClaimFoldArrowsAndRenameButNeverReturn() throws {
        // The static table, not `sidebar.keyCommands`: the property vends nil
        // unless a Library row really holds focus, which a unit test can't
        // arrange.
        let commands = SidebarViewController.treeKeyCommandsForTesting
        let claimed = [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow, UIKeyCommand.f2]
        for input in claimed {
            let command = try XCTUnwrap(
                commands.first { $0.input == input && $0.modifierFlags.isEmpty },
                "sidebar should claim \(input) with no modifiers")
            // Left/Right would otherwise be swallowed by the focus system's
            // lateral-move handling; priority is uniform.
            XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
        }
        let inputs = commands.compactMap(\.input)
        // Decision 2026-08-15 (Return-swallowing investigation): the sidebar
        // must never eat the editor's Return, so Return / keypad-Enter stay
        // unclaimed — the focus system's Space is the keyboard activation.
        XCTAssertFalse(inputs.contains("\r"), "Return must fall through to the editor")
        XCTAssertFalse(inputs.contains("\u{3}"), "keypad Enter must fall through to the editor")
        // Up/Down belong to the focus system — claiming them would kill the
        // built-in row-to-row focus walk.
        XCTAssertFalse(inputs.contains(UIKeyCommand.inputUpArrow))
        XCTAssertFalse(inputs.contains(UIKeyCommand.inputDownArrow))
    }

    func testCollectionViewOptsIntoKeyboardFocus() {
        XCTAssertTrue(collectionView.allowsFocus, "arrow keys need focus")
        XCTAssertTrue(collectionView.remembersLastFocusedIndexPath, "focus should return to the last row, not jump to the top")
        XCTAssertFalse(collectionView.selectionFollowsFocus, "arrowing must not open files / toggle folders")
    }

    // MARK: Row activation (clicks and the focus system's Space share activate())

    func testActivatingFolderTogglesExpansion() throws {
        let folder = try folderNode()
        XCTAssertFalse(sidebar.isExpandedForTesting(folder))
        sidebar.activate(folder)
        XCTAssertTrue(sidebar.isExpandedForTesting(folder))
        sidebar.activate(folder)
        XCTAssertFalse(sidebar.isExpandedForTesting(folder))
    }

    func testActivatingFileOpensIt() throws {
        let file = try fileNode()
        var opened: [URL] = []
        sidebar.onOpenFile = { opened.append($0) }
        sidebar.activate(file)
        XCTAssertEqual(opened, [file.url])
    }

    func testActivatingPlaceholderIsANoOp() throws {
        // The empty Location's single row is the sentinel.
        let placeholderPath = IndexPath(item: 0, section: 1)
        let placeholder = try XCTUnwrap(sidebar.nodeForTesting(at: placeholderPath))
        var opened: [URL] = []
        sidebar.onOpenFile = { opened.append($0) }
        sidebar.activate(placeholder)
        XCTAssertTrue(opened.isEmpty, "the Empty sentinel is not a real file")
        XCTAssertFalse(sidebar.isExpandedForTesting(placeholder))
    }

    // MARK: Left/Right fold keys

    func testRightExpandsAndLeftCollapsesFolder() throws {
        let folder = try folderNode()
        sidebar.handleFoldKeyForTesting(folder, expanding: true)
        XCTAssertTrue(sidebar.isExpandedForTesting(folder))
        sidebar.handleFoldKeyForTesting(folder, expanding: true) // already open: no-op
        XCTAssertTrue(sidebar.isExpandedForTesting(folder))
        sidebar.handleFoldKeyForTesting(folder, expanding: false)
        XCTAssertFalse(sidebar.isExpandedForTesting(folder))
        sidebar.handleFoldKeyForTesting(folder, expanding: false) // already shut: no-op
        XCTAssertFalse(sidebar.isExpandedForTesting(folder))
    }

    func testFoldKeysIgnoreFiles() throws {
        let file = try fileNode()
        var opened: [URL] = []
        sidebar.onOpenFile = { opened.append($0) }
        sidebar.handleFoldKeyForTesting(file, expanding: true)
        sidebar.handleFoldKeyForTesting(file, expanding: false)
        XCTAssertTrue(opened.isEmpty)
    }

    // MARK: Focus visuals

    func testPlaceholderRowIsNotFocusable() {
        XCTAssertFalse(sidebar.collectionView(collectionView, canFocusItemAt: IndexPath(item: 0, section: 1)))
        XCTAssertTrue(sidebar.collectionView(collectionView, canFocusItemAt: IndexPath(item: 0, section: 0)))
    }

    func testFocusedRowPaintsSelectionPill() {
        let focused = SidebarViewController.rowBackground(
            isDropTarget: false, isSelected: false, isFocused: true, isHoveredOrHighlighted: false)
        XCTAssertEqual(focused.backgroundColor, .chalkRowSelection)
        XCTAssertEqual(focused.cornerRadius, ChalkMetrics.rowCornerRadius)

        let idle = SidebarViewController.rowBackground(
            isDropTarget: false, isSelected: false, isFocused: false, isHoveredOrHighlighted: false)
        XCTAssertEqual(idle.backgroundColor, .clear, "idle rows paint no pill")

        let hovered = SidebarViewController.rowBackground(
            isDropTarget: false, isSelected: false, isFocused: false, isHoveredOrHighlighted: true)
        XCTAssertEqual(hovered.backgroundColor, .chalkRowHoverBackground)

        // Drop target outranks everything — the landing-zone pill must not
        // flicker away because the row happens to be focused.
        let drop = SidebarViewController.rowBackground(
            isDropTarget: true, isSelected: true, isFocused: true, isHoveredOrHighlighted: true)
        XCTAssertEqual(drop.backgroundColor, .chalkRowSelection)
    }

    func testCellsSuppressSystemFocusHalo() throws {
        let cell = try XCTUnwrap(collectionView.cellForItem(at: IndexPath(item: 0, section: 0)))
        XCTAssertNil(cell.focusEffect, "the Ink pill replaces the system halo")
    }
}
