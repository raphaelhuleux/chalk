import XCTest
import ChalkKit
@testable import ChalkMac

/// The Library lists images and PDFs beside the documents (owner request,
/// 2026-08-17). They are binary, so every open path has to fork: a document
/// still opens in an editor tab, an asset goes to the preview. A png reaching
/// `editor.open` would render its bytes as Markdown.
///
/// The preview sheet itself arrives with phase 4 of the plan; the routing is
/// pinned here so no asset can reach a tab in the meantime.
@MainActor
final class AssetPreviewRoutingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-asset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# hi".write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        // A REAL png, so the preview (once it decodes) exercises the success path.
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("figure.png"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeRoot() -> RootSplitViewController {
        let shell = RootSplitViewController()
        shell.loadViewIfNeeded()
        shell.view.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        shell.view.layoutSubtreeIfNeeded()
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
    /// offers the preview in their place.
    func testAssetRowMenuOffersPreviewOnly() throws {
        let sidebar = SidebarViewController()
        sidebar.locationsProvider = { [Location(id: "test", name: "Root", url: self.root)] }
        sidebar.loadViewIfNeeded()
        sidebar.reload()

        var previewed: [URL] = []
        sidebar.onPreviewFile = { previewed.append($0) }

        let png = root.appendingPathComponent("figure.png")
        let menu = sidebar.rowMenu(
            for: FileNode(url: png, name: "figure.png", isDirectory: false))

        XCTAssertNil(item(in: menu, titled: "Open in New Tab"))
        XCTAssertNil(item(in: menu, titled: "Open in New Window"))
        // Rename / Move to Trash still apply: it is a file in the Library.
        XCTAssertNotNil(item(in: menu, titled: "Rename"))
        XCTAssertNotNil(item(in: menu, titled: "Move to Trash"))

        perform(try XCTUnwrap(item(in: menu, titled: "Preview")))
        XCTAssertEqual(previewed, [png])
    }
}
