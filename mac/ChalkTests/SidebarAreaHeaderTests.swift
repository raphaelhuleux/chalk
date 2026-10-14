import XCTest
import ChalkKit
@testable import Chalk

/// The Library as Paper draws it (2026-08-24): areas with counts, and one pill
/// that marks where you are.
@MainActor
final class SidebarAreaHeaderTests: XCTestCase {
    private var window: UIWindow!
    private var sidebar: SidebarViewController!
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-areas-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["alpha.md", "beta.md", "gamma.tex"] {
            try? Data("# \(name)\n".utf8).write(to: root.appendingPathComponent(name))
        }
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try? Data("# deep\n".utf8).write(
            to: root.appendingPathComponent("nested/deep.md"))

        sidebar = SidebarViewController()
        sidebar.locationsProvider = { [Location(id: "test", name: "Test", url: self.root)] }
        window = UIWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 320, height: 700))
        window.rootViewController = sidebar
        window.isHidden = false
        sidebar.loadViewIfNeeded()
        sidebar.reload()
        settle()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        sidebar = nil
        root = nil
        super.tearDown()
    }

    private func settle() {
        window.layoutIfNeeded()
        sidebar.collectionViewForTesting.layoutIfNeeded()
    }

    /// A fold schedules its rebuild off the main thread (the tree walk is what
    /// used to freeze the app), and the header refresh follows the apply — so
    /// the slot swap lands over several runloop turns. Spin until it does.
    private func settleUntil(
        _ predicate: () -> Bool, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            settle()
            if predicate() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail(message, file: file, line: line)
    }

    private func node(named name: String) throws -> FileNode {
        let all = (0..<sidebar.collectionViewForTesting.numberOfItems(inSection: 0))
            .compactMap { sidebar.nodeForTesting(at: IndexPath(item: $0, section: 0)) }
        return try XCTUnwrap(all.first { $0.name == name },
                             "the Library should list \(name); it has \(all.map(\.name))")
    }

    // MARK: - Area headers carry a count

    /// The artboard's header is a name and a number. The number is the area's
    /// TOP-LEVEL entries — what the list shows when you open it, not a
    /// recursive file count, which would say a different thing every time a
    /// subfolder changed.
    func testTheAreaHeaderCountsItsTopLevelEntries() throws {
        let slot = try XCTUnwrap(sidebar.headerSlotForTesting(section: 0))
        XCTAssertEqual(slot.count, "4",
                       "three files and one folder at the top level")
        XCTAssertFalse(slot.showsChevron,
                       "an open area shows its count; the chevron is the folded state's mark")
    }

    /// One slot, never both: folding replaces the count with the chevron, in a
    /// fixed frame, so the header's text never shifts.
    func testFoldingSwapsTheCountForTheChevron() throws {
        let header = try XCTUnwrap(
            sidebar.collectionViewForTesting.supplementaryView(
                forElementKind: UICollectionView.elementKindSectionHeader,
                at: IndexPath(item: 0, section: 0)))
        sidebar.toggleFoldForTesting(onHeader: header)
        settleUntil({ self.sidebar.headerSlotForTesting(section: 0)?.showsChevron == true },
                    "a folded area says so")
        XCTAssertTrue(sidebar.isLocationCollapsedForTesting("test"), "precondition: it folded")
        XCTAssertEqual(sidebar.headerSlotForTesting(section: 0)?.count, "",
                       "and the count it hides goes with the rows")

        sidebar.toggleFoldForTesting(onHeader: header)
        settleUntil({ self.sidebar.headerSlotForTesting(section: 0)?.showsChevron == false },
                    "unfolding brings the count back")
        XCTAssertEqual(sidebar.headerSlotForTesting(section: 0)?.count, "4")
    }

    // MARK: - The Library marks the open document (audit PA-9)

    func testTheOpenDocumentCarriesTheRowPill() throws {
        let alpha = try node(named: "alpha.md")
        let beta = try node(named: "beta.md")

        XCTAssertFalse(sidebar.rowIsMarkedForTesting(alpha),
                       "precondition: nothing is open yet, so nothing is marked")

        sidebar.setOpenDocument(alpha.url)
        settle()
        XCTAssertTrue(sidebar.rowIsMarkedForTesting(alpha),
                      "the panel has to show where you are, not only what exists")
        XCTAssertFalse(sidebar.rowIsMarkedForTesting(beta))

        sidebar.setOpenDocument(beta.url)
        settle()
        XCTAssertFalse(sidebar.rowIsMarkedForTesting(alpha), "the mark moves with the reader")
        XCTAssertTrue(sidebar.rowIsMarkedForTesting(beta))

        sidebar.setOpenDocument(nil)
        settle()
        XCTAssertFalse(sidebar.rowIsMarkedForTesting(beta),
                       "a draft with no URL marks nothing")
    }

    /// The host pushes the open document from `handleTabsChanged`, which runs
    /// on the restore path before this view controller has ever been asked for
    /// its view. That crashed on an implicitly-unwrapped data
    /// source; it must be a no-op instead.
    func testMarkingBeforeTheViewLoadsIsANoOpNotACrash() {
        let fresh = SidebarViewController()
        fresh.setOpenDocument(URL(fileURLWithPath: "/tmp/whatever.md"))
        fresh.setOpenDocument(nil)
    }
}
