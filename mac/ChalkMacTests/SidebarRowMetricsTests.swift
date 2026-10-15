import XCTest
import ChalkKit
@testable import ChalkMac

/// Rigid sidebar scrolling (owner report 2026-08-18: "items stretch around,
/// with a weird animation I didn't ask for"). On Catalyst the motion came from
/// list defaults leaking through the row builder: estimated row heights that
/// corrected on screen, cell content filled in a later pass, and a fresh
/// chevron view per update that read as an accessory swap.
///
/// These pin the invariants that keep the list rigid: every row is the token
/// height, a cell is complete when it leaves the delegate, the rename row fits
/// the same height, and a repaint reuses its chevron view.
@MainActor
final class SidebarRowMetricsTests: XCTestCase {
    private var window: NSWindow!
    private var sidebar: SidebarViewController!
    private var root: URL!

    private var outlineView: LibraryOutlineView { sidebar.outlineViewForTesting }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Root/
        //   Papers/draft.tex
        //   index.md
        //   notes.md
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-rowmetrics-\(UUID().uuidString)")
        let papers = root.appendingPathComponent("Papers")
        try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
        try "x".write(to: papers.appendingPathComponent("draft.tex"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        (sidebar, window) = makeHostedSidebar(locations: [Location(id: "main", name: "Root", url: root)])
    }

    override func tearDownWithError() throws {
        dismantleHostedSidebar(window)
        window = nil
        sidebar = nil
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func folderNode() throws -> FileNode {
        try XCTUnwrap(FileTree.children(of: root).first(where: \.isDirectory))
    }

    private func fileNode() throws -> FileNode {
        try XCTUnwrap(FileTree.children(of: root).first { !$0.isDirectory })
    }

    // MARK: Height

    /// Rows must NOT self-size. Every one is the design token, so a row's
    /// height never changes after it is laid out.
    func testEveryRowIsTheTokenHeight() throws {
        XCTAssertGreaterThan(outlineView.numberOfRows, 1, "the fixture should render rows")
        for row in 0..<outlineView.numberOfRows where outlineView.item(atRow: row) is LibraryRowItem {
            XCTAssertEqual(
                outlineView.rect(ofRow: row).height, ChalkMetrics.sidebarRowHeight, accuracy: 0.5,
                "row \(row) must be pinned to the token, not self-sized")
        }
    }

    /// The first header sits on the chrome floor with 8pt of air; the ones
    /// between areas carry the 22pt block.
    func testHeadersCarryTheirMargins() throws {
        let first = try XCTUnwrap(sidebar.headerRectForTesting(section: 0))
        XCTAssertEqual(first.height, LibraryHeaderCellView.height(isFirst: true, needsReauthorization: false))
        XCTAssertLessThan(LibraryHeaderCellView.height(isFirst: true, needsReauthorization: false),
                          LibraryHeaderCellView.height(isFirst: false, needsReauthorization: false))
        XCTAssertGreaterThan(LibraryHeaderCellView.height(isFirst: false, needsReauthorization: true),
                             LibraryHeaderCellView.height(isFirst: false, needsReauthorization: false),
                             "the no-access line adds a second line")
    }

    /// The clamp must not be tighter than the inline-rename row, which turns
    /// the same label into a field.
    func testRenameRowFitsTheFixedHeight() throws {
        let file = try fileNode()
        let cell = try XCTUnwrap(sidebar.dequeuedCellForTesting(file))
        cell.beginEditing(name: file.name, onCommit: { _ in true }, onCancel: {})
        XCTAssertLessThanOrEqual(
            cell.fittingSize.height, ChalkMetrics.sidebarRowHeight + 0.5,
            "the rename row must fit the pinned height or its constraints break")
    }

    // MARK: First layout

    /// A cell leaves the delegate fully configured: name and glyph set, so the
    /// first measurement is the real row.
    func testRowContentIsPopulatedOnDequeue() throws {
        let node = try XCTUnwrap(sidebar.nodeForTesting(at: IndexPath(item: 0, section: 0)))
        let cell = try XCTUnwrap(sidebar.dequeuedCellForTesting(node))
        XCTAssertEqual(cell.label.stringValue, node.name)
        XCTAssertNotNil(cell.icon.image, "the row glyph is part of the first measurement")
    }

    // MARK: Accessory stability

    /// Repainting a folder row must reuse its chevron view.
    func testRepaintingAFolderRowKeepsTheSameChevronView() throws {
        let folder = try folderNode()
        let first = try XCTUnwrap(sidebar.chevronViewForTesting(folder), "a folder row carries a chevron")
        XCTAssertFalse(first.isHidden)
        sidebar.repaintRows(for: [folder])
        outlineView.layoutSubtreeIfNeeded()
        let second = try XCTUnwrap(sidebar.chevronViewForTesting(folder))
        XCTAssertTrue(first === second, "the chevron view must be reused across repaints")
        let file = try fileNode()
        XCTAssertTrue(try XCTUnwrap(sidebar.chevronViewForTesting(file)).isHidden, "files have no chevron")
    }

    /// Files indent past the folder rows' chevron slot, so their glyphs line
    /// up; nested rows step in by one unit per level.
    func testRowsIndentByKindAndLevel() throws {
        let folder = try folderNode()
        let file = try fileNode()
        let folderCell = try XCTUnwrap(sidebar.cellForTesting(folder))
        let fileCell = try XCTUnwrap(sidebar.cellForTesting(file))
        outlineView.layoutSubtreeIfNeeded()
        XCTAssertEqual(folderCell.frame.minX, 0, accuracy: 0.5, "the cell spans the row; it indents itself")
        XCTAssertEqual(folderCell.frame.width, outlineView.bounds.width, accuracy: 0.5)
        XCTAssertEqual(folderCell.chevron.frame.minX, LibraryCellView.folderLeading, accuracy: 0.5)
        XCTAssertEqual(fileCell.icon.frame.minX, LibraryCellView.fileLeading, accuracy: 0.5)
        XCTAssertEqual(folderCell.icon.frame.minX, fileCell.icon.frame.minX, accuracy: 0.5,
                       "a folder's glyph lines up with a file's")

        sidebar.activate(folder)
        settleSidebar(sidebar, window)
        let nested = try XCTUnwrap(sidebar.rowsForTesting(inSection: 0).first { $0.name == "draft.tex" })
        let nestedCell = try XCTUnwrap(sidebar.cellForTesting(nested))
        outlineView.layoutSubtreeIfNeeded()
        XCTAssertEqual(nestedCell.icon.frame.minX, LibraryCellView.fileLeading + LibraryCellView.indentUnit,
                       accuracy: 0.5, "one level in, one unit over")
    }
}
