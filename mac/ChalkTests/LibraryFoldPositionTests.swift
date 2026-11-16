import XCTest
import ChalkKit
@testable import Chalk

/// Folding a Location must not move its header: the header is what the
/// reader clicked, so it stays under the pointer through a fold round trip.
@MainActor
final class LibraryFoldPositionTests: XCTestCase {
    private var window: NSWindow!
    private var root: RootSplitViewController!
    private var dirs: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        root = RootSplitViewController()
        root.motionPolicyForTesting = .instant
        window.rootViewController = root
        window.isHidden = false
    }

    override func tearDownWithError() throws {
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        root = nil
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        try super.tearDownWithError()
    }

    private func makeLocation(files: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-fold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<files {
            try Data("# \(i)\n".utf8).write(to: dir.appendingPathComponent(String(format: "f%02d.md", i)))
        }
        dirs.append(dir)
        return dir
    }

    private func settle() {
        for _ in 0..<6 {
            window.layoutIfNeeded()
            root.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
    }

    private var sidebar: SidebarViewController { root.sidebarForTesting }

    /// The first header's row and name label, in window coordinates, plus the scroll offset.
    private func snapshot() throws -> (row: CGRect, name: CGRect, offset: CGFloat) {
        let outline = sidebar.outlineViewForTesting
        let rowRect = try XCTUnwrap(sidebar.headerRectForTesting(section: 0))
        let row = outline.row(at: CGPoint(x: rowRect.midX, y: rowRect.midY))
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? LibraryHeaderCellView)
        return (outline.convert(rowRect, to: nil),
                cell.nameLabel.convert(cell.nameLabel.bounds, to: nil),
                root.libraryScrollOffsetForTesting)
    }

    private func assertFoldRoundTripKeepsTheHeader(files: Int, line: UInt = #line) throws {
        let dir = try makeLocation(files: files)
        let other = try makeLocation(files: 3)
        root.setLibraryLocationsForTesting([dir, other])
        root.applyTransitionForTesting(.sidebar(true))
        settle()
        let id = dir.lastPathComponent
        let before = try snapshot()
        sidebar.toggleFoldForTesting(locationID: id)
        settle()
        XCTAssertTrue(sidebar.isLocationCollapsedForTesting(id), line: line)
        let folded = try snapshot()
        sidebar.toggleFoldForTesting(locationID: id)
        settle()
        let unfolded = try snapshot()
        XCTAssertEqual(folded.row, before.row, "folding moved the header row", line: line)
        XCTAssertEqual(folded.name, before.name, "folding moved the header name", line: line)
        XCTAssertEqual(unfolded.row, before.row, "unfolding moved the header row", line: line)
        XCTAssertEqual(unfolded.name, before.name, "unfolding moved the header name", line: line)
    }

    func testFoldingAShortLocationKeepsItsHeader() throws {
        try assertFoldRoundTripKeepsTheHeader(files: 3)
    }

    func testFoldingALocationTallerThanTheColumnKeepsItsHeader() throws {
        try assertFoldRoundTripKeepsTheHeader(files: 40)
    }

    /// Auto-hide slides the band away but the titlebar stays, so a fold (which
    /// lays the Library out again) must not lift the list into the gap.
    func testFoldingWhileTheBandIsAutoHiddenKeepsTheHeader() throws {
        let key = "chalk.autoHideChrome"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        Preferences.autoHideChrome = true
        NotificationCenter.default.post(name: Preferences.autoHideChromeDidChange, object: nil)
        let dir = try makeLocation(files: 5)
        root.setLibraryLocationsForTesting([dir])
        root.applyTransitionForTesting(.sidebar(true))
        settle()
        let shown = try snapshot()
        for offset in stride(from: 100.0, through: 160.0, by: 10.0) {
            root.editorDidScroll(offset: offset, canHide: true)
        }
        settle()
        XCTAssertTrue(root.isChromeAutoHiddenForTesting, "precondition: the band slid away")
        let hidden = try snapshot()
        sidebar.toggleFoldForTesting(locationID: dir.lastPathComponent)
        settle()
        let folded = try snapshot()
        XCTAssertEqual(hidden.row, shown.row, "the band sliding away moved the list")
        XCTAssertEqual(folded.row, shown.row, "folding under a hidden band moved the header")
    }
}
