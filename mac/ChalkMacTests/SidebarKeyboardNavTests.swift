import XCTest
import ChalkKit
@testable import ChalkMac

/// Keyboard navigation for the Library tree.
///
/// Contract under test:
/// - Return / keypad-Enter are deliberately UNCLAIMED (decision 2026-08-15:
///   the sidebar must never eat the editor's Return); keyboard activation is
///   Space, through the shared activate() path (folders toggle, files open,
///   the "Empty" sentinel is inert).
/// - Left/Right fold/unfold a selected folder, Finder-style; F2 renames.
/// - Up/Down stay with the table (nothing claims them).
/// - Selected rows paint the selection pill; the system highlight is off.
/// - The "Empty" sentinel row can't be selected at all.
@MainActor
final class SidebarKeyboardNavTests: XCTestCase {
    private var window: NSWindow!
    private var sidebar: SidebarViewController!
    private var root: URL!
    private var emptyRoot: URL!

    private var outlineView: LibraryOutlineView { sidebar.outlineViewForTesting }

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

        (sidebar, window) = makeHostedSidebar(locations: [
            Location(id: "main", name: "Root", url: root),
            Location(id: "empty", name: "Empty", url: emptyRoot),
        ])
    }

    override func tearDownWithError() throws {
        dismantleHostedSidebar(window)
        window = nil
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

    private func keyEvent(_ characters: String, keyCode: UInt16 = 0) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
    }

    // MARK: Key claims

    func testKeyClaimsCoverFoldArrowsRenameAndSpaceButNeverReturn() throws {
        let inputs = SidebarViewController.treeKeyClaimsForTesting.map(\.input)
        for claimed in [String(UnicodeScalar(NSLeftArrowFunctionKey)!),
                        String(UnicodeScalar(NSRightArrowFunctionKey)!),
                        String(UnicodeScalar(NSF2FunctionKey)!), " "] {
            XCTAssertTrue(inputs.contains(claimed), "the tree should claim \(claimed.unicodeScalars.first!.value)")
        }
        // Decision 2026-08-15 (Return-swallowing investigation): the sidebar
        // must never eat the editor's Return.
        XCTAssertFalse(inputs.contains("\r"), "Return must fall through")
        XCTAssertFalse(inputs.contains("\u{3}"), "keypad Enter must fall through")
        // Up/Down belong to the table: claiming them would kill the built-in walk.
        XCTAssertFalse(inputs.contains(String(UnicodeScalar(NSUpArrowFunctionKey)!)))
        XCTAssertFalse(inputs.contains(String(UnicodeScalar(NSDownArrowFunctionKey)!)))

        // The same table, read through the event classifier the view uses.
        XCTAssertEqual(LibraryOutlineView.claim(for: try XCTUnwrap(keyEvent(String(UnicodeScalar(NSF2FunctionKey)!), keyCode: 120))), .rename)
        XCTAssertEqual(LibraryOutlineView.claim(for: try XCTUnwrap(keyEvent(" ", keyCode: 49))), .activate)
        XCTAssertNil(LibraryOutlineView.claim(for: try XCTUnwrap(keyEvent("\r", keyCode: 36))))
    }

    func testTheTableTakesTheKeyboardWithoutSystemHighlight() {
        XCTAssertTrue(outlineView.acceptsFirstResponder, "arrow keys need the keyboard")
        XCTAssertEqual(outlineView.selectionHighlightStyle, .none, "the Ink pill replaces the system highlight")
        XCTAssertEqual(outlineView.focusRingType, .none)
        XCTAssertTrue(outlineView.allowsEmptySelection)
        XCTAssertFalse(outlineView.allowsMultipleSelection)
    }

    // MARK: Row activation (clicks and Space share activate())

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
        let placeholder = try XCTUnwrap(sidebar.nodeForTesting(at: IndexPath(item: 0, section: 1)))
        XCTAssertEqual(placeholder.name, "Empty")
        var opened: [URL] = []
        sidebar.onOpenFile = { opened.append($0) }
        sidebar.activate(placeholder)
        XCTAssertTrue(opened.isEmpty, "the Empty sentinel is not a real file")
        XCTAssertFalse(sidebar.isExpandedForTesting(placeholder))
    }

    /// Space on the selected row runs the same activation a click does.
    func testSpaceActivatesTheSelectedRow() throws {
        let file = try fileNode()
        var opened: [URL] = []
        sidebar.onOpenFile = { opened.append($0) }
        let row = try XCTUnwrap(sidebar.rowForTesting(file))
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.keyDown(with: try XCTUnwrap(keyEvent(" ", keyCode: 49)))
        XCTAssertEqual(opened, [file.url])
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

    // MARK: Selection visuals

    func testPlaceholderRowIsNotSelectable() throws {
        let placeholder = try XCTUnwrap(sidebar.nodeForTesting(at: IndexPath(item: 0, section: 1)))
        let placeholderItem = try XCTUnwrap(sidebar.item(for: placeholder))
        let first = try XCTUnwrap(sidebar.item(for: try XCTUnwrap(sidebar.nodeForTesting(at: IndexPath(item: 0, section: 0)))))
        XCTAssertFalse(sidebar.outlineView(outlineView, shouldSelectItem: placeholderItem))
        XCTAssertTrue(sidebar.outlineView(outlineView, shouldSelectItem: first))
        XCTAssertFalse(sidebar.outlineView(outlineView, shouldSelectItem: try XCTUnwrap(sidebar.sections.first)),
                       "headers fold, they never select")
    }

    func testSelectedRowPaintsSelectionPill() {
        let selected = SidebarViewController.rowBackground(
            isDropTarget: false, isSelected: false, isFocused: true, isHoveredOrHighlighted: false)
        XCTAssertEqual(selected.backgroundColor, .chalkRowSelection)
        XCTAssertEqual(selected.cornerRadius, ChalkMetrics.rowCornerRadius)

        let idle = SidebarViewController.rowBackground(
            isDropTarget: false, isSelected: false, isFocused: false, isHoveredOrHighlighted: false)
        XCTAssertNil(idle.backgroundColor, "idle rows paint no pill")

        let hovered = SidebarViewController.rowBackground(
            isDropTarget: false, isSelected: false, isFocused: false, isHoveredOrHighlighted: true)
        XCTAssertEqual(hovered.backgroundColor, .chalkRowHoverBackground)

        // Drop target outranks everything: the landing-zone pill must not
        // flicker away because the row happens to be selected.
        let drop = SidebarViewController.rowBackground(
            isDropTarget: true, isSelected: true, isFocused: true, isHoveredOrHighlighted: true)
        XCTAssertEqual(drop.backgroundColor, .chalkRowSelection)
    }

    /// A selected row carries the pill, read off the live row view.
    func testSelectingARowMarksIt() throws {
        let file = try fileNode()
        let row = try XCTUnwrap(sidebar.rowForTesting(file))
        XCTAssertFalse(sidebar.rowIsMarkedForTesting(file))
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        XCTAssertTrue(sidebar.rowIsMarkedForTesting(file))
    }
}
