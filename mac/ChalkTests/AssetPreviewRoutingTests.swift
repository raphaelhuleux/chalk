import XCTest
import ChalkKit
@testable import Chalk

/// The Library lists images and PDFs beside the documents (owner request,
/// 2026-08-17). They are binary, so every open path has to fork: a document
/// still opens in an editor tab, an asset opens in a Quick Look preview.
/// A png reaching `editor.open` would render its bytes as Markdown.
@MainActor
final class AssetPreviewRoutingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-asset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# hi".write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        // A REAL png: the sheet decodes it with `UIImage(contentsOfFile:)`, so
        // a stub of magic bytes would exercise only the failure path.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        try XCTUnwrap(image.pngData()).write(to: root.appendingPathComponent("figure.png"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeRoot() -> RootSplitViewController {
        let shell = RootSplitViewController()
        shell.loadViewIfNeeded()
        shell.view.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        shell.view.layoutIfNeeded()
        return shell
    }

    // MARK: - Shell routing (sidebar click and Quick Open share it)

    func testAssetPreviewsInsteadOfOpeningATab() {
        let shell = makeRoot()
        let before = shell.editorForTesting.tabItemsForTesting.count

        shell.openFromLibrary(root.appendingPathComponent("figure.png"))

        XCTAssertEqual(shell.lastPreviewedAssetForTesting, root.appendingPathComponent("figure.png"))
        XCTAssertEqual(shell.editorForTesting.tabItemsForTesting.count, before,
                       "an asset must not spawn an editor tab")
    }

    func testDocumentStillOpensInTheEditor() {
        let shell = makeRoot()
        let note = root.appendingPathComponent("note.md")

        shell.openFromLibrary(note)

        XCTAssertNil(shell.lastPreviewedAssetForTesting)
        // TabItem carries the display name, not the URL.
        XCTAssertTrue(shell.editorForTesting.tabItemsForTesting.contains { $0.name.hasPrefix("note") },
                      "expected a tab for \(note.lastPathComponent)")
    }

    /// The sheet is in-process (an image view, not the Quick Look extension),
    /// so it must actually be presented and carry the file.
    func testAssetPresentsAnInAppPreviewSheetOnce() throws {
        let shell = makeRoot()
        let window = UIWindow.hostedForTesting(frame: shell.view.frame)
        window.rootViewController = shell
        window.isHidden = false
        defer { window.isHidden = true }

        let png = root.appendingPathComponent("figure.png")
        shell.openFromLibrary(png)
        // A row click can dispatch twice in one turn; the second must no-op.
        shell.openFromLibrary(png)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let nav = try XCTUnwrap(shell.presentedViewController as? UINavigationController)
        let preview = try XCTUnwrap(nav.viewControllers.first as? AssetPreviewViewController)
        XCTAssertEqual(preview.url, png)
        XCTAssertEqual(preview.title, "figure.png")
        XCTAssertNil(nav.presentedViewController, "a second click stacked another sheet")
    }

    // MARK: - Sidebar row behaviour

    func testSidebarActivationRoutesAssetsToPreview() {
        let sidebar = SidebarViewController()
        sidebar.locationsProvider = { [Location(id: "test", name: "Root", url: self.root)] }
        sidebar.loadViewIfNeeded()
        sidebar.reload()

        var opened: [URL] = []
        var previewed: [URL] = []
        sidebar.onOpenFile = { opened.append($0) }
        sidebar.onPreviewFile = { previewed.append($0) }

        let png = root.appendingPathComponent("figure.png")
        sidebar.activate(FileNode(url: png, name: "figure.png", isDirectory: false))
        let md = root.appendingPathComponent("note.md")
        sidebar.activate(FileNode(url: md, name: "note.md", isDirectory: false))

        XCTAssertEqual(previewed, [png])
        XCTAssertEqual(opened, [md])
    }

    /// "Open in New Tab"/"New Window" are meaningless for a png: the asset row
    /// offers Quick Look in their place.
    func testAssetRowMenuOffersQuickLookOnly() throws {
        let sidebar = SidebarViewController()
        sidebar.locationsProvider = { [Location(id: "test", name: "Root", url: self.root)] }
        sidebar.loadViewIfNeeded()
        sidebar.reload()

        var previewed: [URL] = []
        sidebar.onPreviewFile = { previewed.append($0) }

        let png = root.appendingPathComponent("figure.png")
        let menu = sidebar.rowMenu(
            for: FileNode(url: png, name: "figure.png", isDirectory: false))

        XCTAssertNil(action(in: menu, titled: "Open in New Tab"))
        XCTAssertNil(action(in: menu, titled: "Open in New Window"))
        // Rename / Move to Trash still apply: it is a file in the Library.
        XCTAssertNotNil(action(in: menu, titled: "Rename"))
        XCTAssertNotNil(action(in: menu, titled: "Move to Trash"))

        let preview = try XCTUnwrap(action(in: menu, titled: "Preview"))
        preview.performWithSender(nil, target: nil)
        XCTAssertEqual(previewed, [png])
    }

    private func action(in menu: UIMenu, titled title: String) -> UIAction? {
        for element in menu.children {
            if let action = element as? UIAction, action.title == title { return action }
            if let submenu = element as? UIMenu, let hit = self.action(in: submenu, titled: title) {
                return hit
            }
        }
        return nil
    }
}
