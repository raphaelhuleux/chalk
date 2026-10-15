import XCTest
import ChalkKit
@testable import ChalkMac

/// U12 drag-move landing zones. The reported bug: a file dragged out of a
/// folder had nowhere to land at the Location's top level; only the thin
/// header strip resolved to a target, so dropping on a top-level row or in the
/// blank space under the tree was refused.
///
/// This drives the real outline view (rows laid out, sections built from a
/// temp-dir Location) and asks where a drop at a given point would land.
@MainActor
final class SidebarDropTargetTests: XCTestCase {
    private var window: NSWindow!
    private var sidebar: SidebarViewController!
    private var root: URL!

    private var outlineView: LibraryOutlineView { sidebar.outlineViewForTesting }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Root/
        //   Papers/draft.tex
        //   index.md
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-drop-\(UUID().uuidString)")
        let papers = root.appendingPathComponent("Papers")
        try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
        try "x".write(to: papers.appendingPathComponent("draft.tex"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)

        (sidebar, window) = makeHostedSidebar(locations: [Location(id: "test", name: "Root", url: root)])
        sidebar.expandAll() // Papers' children have to be rows for the nested case
        settleSidebar(sidebar, window)
    }

    override func tearDownWithError() throws {
        dismantleHostedSidebar(window)
        window = nil
        sidebar = nil
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// The row whose URL ends in `name`.
    private func row(named name: String) throws -> Int {
        let rows = sidebar.rowsForTesting(inSection: 0)
        let node = try XCTUnwrap(rows.first { $0.url.lastPathComponent == name },
                                 "no row named \(name); the tree did not build: \(rows.map(\.name))")
        return try XCTUnwrap(sidebar.rowForTesting(node), "\(name) has no table row")
    }

    /// Compare resolved paths, not raw ones: on macOS /var is a symlink to
    /// /private/var, and the two sides reach the temporary directory by
    /// different routes.
    private func assertSameDirectory(_ actual: URL?, _ expected: URL,
                                     _ message: String = "",
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        XCTAssertEqual(actual?.resolvingSymlinksInPath().standardizedFileURL,
                       expected.resolvingSymlinksInPath().standardizedFileURL,
                       message, file: file, line: line)
    }

    private func center(ofRow row: Int) -> CGPoint {
        let rect = outlineView.rect(ofRow: row)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func testDropOnFolderRowLandsInThatFolder() throws {
        let row = try row(named: "Papers")
        assertSameDirectory(sidebar.dropDestinationForTesting(at: center(ofRow: row)),
                            root.appendingPathComponent("Papers"))
    }

    func testDropOnTopLevelFileRowLandsAtTheLocationRoot() throws {
        let row = try row(named: "index.md")
        assertSameDirectory(sidebar.dropDestinationForTesting(at: center(ofRow: row)),
                            root,
                            "this is the way a file gets dragged back OUT of a folder")
    }

    func testDropOnNestedFileRowLandsInItsContainingFolder() throws {
        let row = try row(named: "draft.tex")
        assertSameDirectory(sidebar.dropDestinationForTesting(at: center(ofRow: row)),
                            root.appendingPathComponent("Papers"))
    }

    func testDropInBlankSpaceBelowTheTreeLandsAtTheLocationRoot() throws {
        let lastRow = outlineView.rect(ofRow: outlineView.numberOfRows - 1)
        let blank = CGPoint(x: outlineView.bounds.midX, y: lastRow.maxY + 40)
        XCTAssertEqual(sidebar.dropDestinationForTesting(at: blank)?.path, root.path)
    }

    /// The table fills its clip view, so the blank space under the rows is
    /// still the table's: a drop there arrives.
    func testTheTableReachesTheBlankSpaceUnderTheRows() {
        let lastRow = outlineView.rect(ofRow: outlineView.numberOfRows - 1)
        XCTAssertGreaterThan(outlineView.bounds.height, lastRow.maxY + 40,
                             "the outline view must extend past its last row to take drops there")
    }

    func testDropOnTheLocationHeaderStillLandsAtTheLocationRoot() throws {
        let header = try XCTUnwrap(sidebar.headerRectForTesting(section: 0))
        XCTAssertEqual(sidebar.dropDestinationForTesting(at: CGPoint(x: header.midX, y: header.midY))?.path,
                       root.path)
    }

    func testDropAboveEverythingIsNoTarget() {
        let above = CGPoint(x: outlineView.bounds.midX, y: -200)
        XCTAssertNil(sidebar.dropDestinationForTesting(at: above))
    }
}
