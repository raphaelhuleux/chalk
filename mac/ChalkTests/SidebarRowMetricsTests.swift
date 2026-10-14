import XCTest
import ChalkKit
@testable import Chalk

/// Rigid sidebar scrolling (owner report 2026-08-18: "items stretch around,
/// with a weird animation I didn't ask for"). Nothing observes the scroll —
/// the motion came from UIKit defaults leaking through the row builder:
///
/// - the list layout sizes items `.estimated(44)` while real rows are ~33pt,
///   so every row entering the viewport corrected its own height and the
///   scroll offset was compensated under it;
/// - the whole cell body lived in `configurationUpdateHandler`, which UIKit
///   runs a layout pass LATE, so the first measurement happened on an empty
///   cell and the correction landed on a row already on screen;
/// - a fresh `UIImageView` chevron per update reads to UIKit as
///   remove-old + insert-new, so even repainting the same folder row animated
///   its accessory.
///
/// These four pin the invariants that keep the list rigid. Nothing else in the
/// suite asserts row height, first-layout content, or accessory stability.
@MainActor
final class SidebarRowMetricsTests: XCTestCase {
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
        //   notes.md
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-rowmetrics-\(UUID().uuidString)")
        let papers = root.appendingPathComponent("Papers")
        try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
        try "x".write(to: papers.appendingPathComponent("draft.tex"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        sidebar = SidebarViewController()
        sidebar.locationsProvider = { [Location(id: "main", name: "Root", url: self.root)] }
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
    /// height never changes after it is laid out and the scroll offset is
    /// never compensated mid-drag.
    func testEveryRowIsTheTokenHeight() throws {
        let cells = collectionView.visibleCells
        XCTAssertFalse(cells.isEmpty, "the fixture should render rows")
        for cell in cells {
            XCTAssertEqual(
                cell.bounds.height, ChalkMetrics.sidebarRowHeight, accuracy: 0.5,
                "row heights must be pinned to the token, not self-sized from the 44pt estimate")
        }
    }

    /// The clamp must not be tighter than the inline-rename row, which swaps a
    /// text field into the same cell.
    func testRenameRowFitsTheFixedHeight() throws {
        let file = try fileNode()
        let content = SidebarRenameConfiguration(
            node: file, symbol: "doc.text", onCommit: { _ in }, onCancel: {})
        let view = content.makeContentView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: ChalkMetrics.sidebarRowHeight)
        let fitted = view.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        XCTAssertLessThanOrEqual(
            fitted.height, ChalkMetrics.sidebarRowHeight + 0.5,
            "the rename row must fit the pinned height or its constraints break")
    }

    // MARK: First layout

    /// A cell arrives from the data source fully configured. When the content
    /// was built only in `configurationUpdateHandler`, this cell came back with
    /// an empty default configuration and filled in a layout pass later — the
    /// deferred measurement that made rows resize on screen.
    func testRowContentIsPopulatedOnDequeue() throws {
        let indexPath = IndexPath(item: 0, section: 0)
        let node = try XCTUnwrap(sidebar.nodeForTesting(at: indexPath))
        let cell = try XCTUnwrap(sidebar.dequeuedCellForTesting(at: indexPath))
        let content = try XCTUnwrap(
            cell.contentConfiguration as? UIListContentConfiguration,
            "the cell should carry a populated list content configuration straight out of the data source")
        XCTAssertEqual(content.text, node.name)
        XCTAssertNotNil(content.image, "the row glyph is part of the first measurement")
    }

    // MARK: Accessory stability

    /// Repainting a folder row must reuse its chevron view. A new `UIImageView`
    /// each time reads as an accessory removal plus insertion, which UIKit
    /// animates on a visible cell.
    func testRepaintingAFolderRowKeepsTheSameChevronView() throws {
        let folder = try folderNode()
        let indexPath = try XCTUnwrap(sidebar.indexPathForTesting(folder))
        let cell = try XCTUnwrap(
            collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell)

        func chevron() throws -> UIView {
            let accessory = try XCTUnwrap(cell.accessories.first, "a folder row carries a chevron")
            var custom: UIView?
            if case .customView(let view) = accessory.accessoryType { custom = view }
            return try XCTUnwrap(custom, "the chevron should be a custom view accessory")
        }

        let first = try chevron()
        sidebar.repaintRows(for: [folder])
        collectionView.layoutIfNeeded()
        let second = try chevron()
        XCTAssertTrue(first === second, "the chevron view must be reused across repaints")
    }
}
