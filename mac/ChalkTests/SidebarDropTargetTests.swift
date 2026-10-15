import XCTest
import ChalkKit
@testable import Chalk

/// U12 drag-move landing zones. The reported bug: a file dragged out of a
/// folder had nowhere to land at the Location's top level — only the thin
/// header strip resolved to a target, so dropping on a top-level row or in the
/// blank space under the tree was refused.
///
/// This drives the real collection view (rows laid out, sections built from a
/// temp-dir Location) and asks where a drop at a given point would land.
@MainActor
final class SidebarDropTargetTests: XCTestCase {
    private var window: UIWindow!
    private var host: UIViewController!
    private var sidebar: SidebarViewController!
    private var root: URL!

    private var collectionView: UICollectionView { sidebar.collectionViewForTesting }

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

        let location = Location(id: "test", name: "Root", url: root)
        sidebar = SidebarViewController()
        sidebar.locationsProvider = { [location] }
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
        sidebar.expandAll() // Papers' children have to be rows for the nested case
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
        try super.tearDownWithError()
    }

    /// The index path of the row whose URL ends in `name`.
    private func indexPath(forRowNamed name: String) throws -> IndexPath {
        let path = try XCTUnwrap(
            (0..<collectionView.numberOfSections).flatMap { section in
                (0..<collectionView.numberOfItems(inSection: section)).map { IndexPath(item: $0, section: section) }
            }.first { sidebar.itemURLForTesting(at: $0)?.lastPathComponent == name },
            "no row named \(name) — the tree did not build")
        return path
    }

    /// Compare resolved paths, not raw ones.
    ///
    /// On macOS /var is a symlink to /private/var, and the temporary directory
    /// reaches the two sides of these assertions by different routes: the test
    /// builds its expectation from FileManager's URL, while the drop code has
    /// been through the file system. The strings differ by that one prefix and
    /// name the same directory. This is a real difference between the paths
    /// and not a reason to compare something weaker than the destination.
    private func assertSameDirectory(_ actual: URL?, _ expected: URL,
                                     _ message: String = "",
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        XCTAssertEqual(actual?.resolvingSymlinksInPath().standardizedFileURL,
                       expected.resolvingSymlinksInPath().standardizedFileURL,
                       message, file: file, line: line)
    }

    private func center(of indexPath: IndexPath) throws -> CGPoint {
        try XCTUnwrap(collectionView.layoutAttributesForItem(at: indexPath)?.center)
    }

    func testDropOnFolderRowLandsInThatFolder() throws {
        let path = try indexPath(forRowNamed: "Papers")
        assertSameDirectory(sidebar.dropDestinationForTesting(at: try center(of: path), destination: path),
                            root.appendingPathComponent("Papers"))
    }

    func testDropOnTopLevelFileRowLandsAtTheLocationRoot() throws {
        let path = try indexPath(forRowNamed: "index.md")
        assertSameDirectory(sidebar.dropDestinationForTesting(at: try center(of: path), destination: path),
                            root,
                            "this is the way a file gets dragged back OUT of a folder")
    }

    func testDropOnNestedFileRowLandsInItsContainingFolder() throws {
        let path = try indexPath(forRowNamed: "draft.tex")
        assertSameDirectory(sidebar.dropDestinationForTesting(at: try center(of: path), destination: path),
                            root.appendingPathComponent("Papers"))
    }

    func testDropInBlankSpaceBelowTheTreeLandsAtTheLocationRoot() throws {
        let blank = CGPoint(x: collectionView.bounds.midX,
                            y: collectionView.contentSize.height + 40)
        XCTAssertEqual(sidebar.dropDestinationForTesting(at: blank, destination: nil)?.path,
                       root.path)
    }

    func testDropOnTheLocationHeaderStillLandsAtTheLocationRoot() throws {
        let header = try XCTUnwrap(collectionView.collectionViewLayout.layoutAttributesForSupplementaryView(
            ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 0)))
        XCTAssertEqual(sidebar.dropDestinationForTesting(at: header.center, destination: nil)?.path,
                       root.path)
    }

    func testDropAboveEverythingIsNoTarget() {
        let above = CGPoint(x: collectionView.bounds.midX, y: -200)
        XCTAssertNil(sidebar.dropDestinationForTesting(at: above, destination: nil))
    }
}
