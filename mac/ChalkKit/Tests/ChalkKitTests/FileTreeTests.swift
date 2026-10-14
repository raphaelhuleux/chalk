import XCTest
@testable import ChalkKit

final class FileTreeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-filetree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ name: String) throws {
        try Data().write(to: root.appendingPathComponent(name))
    }

    private func mkdir(_ name: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }

    func testFiltersToDocumentsAssetsAndFolders() throws {
        try touch("a.md")
        try touch("b.tex")
        try touch("c.qmd")
        try touch("d.txt")     // ignored
        try touch("e.zip")     // ignored
        try touch("image.png")
        try touch("photo.JPG") // extension match is case-insensitive
        try touch("scan.jpeg")
        try touch("paper.pdf")
        try mkdir("notes")

        let names = FileTree.children(of: root).map(\.name)
        XCTAssertEqual(Set(names), [
            "a.md", "b.tex", "c.qmd",
            "image.png", "photo.JPG", "scan.jpeg", "paper.pdf",
            "notes",
        ])
    }

    /// The two file kinds the Library lists are routed differently by the
    /// hosts: documents open in a tab, assets open in a Quick Look preview.
    func testKindSeparatesDocumentsFromPreviewableAssets() {
        XCTAssertEqual(FileTree.kind(of: root.appendingPathComponent("a.md")), .document)
        XCTAssertEqual(FileTree.kind(of: root.appendingPathComponent("b.TEX")), .document)
        XCTAssertEqual(FileTree.kind(of: root.appendingPathComponent("i.png")), .asset)
        XCTAssertEqual(FileTree.kind(of: root.appendingPathComponent("i.jpg")), .asset)
        XCTAssertEqual(FileTree.kind(of: root.appendingPathComponent("i.jpeg")), .asset)
        XCTAssertEqual(FileTree.kind(of: root.appendingPathComponent("p.pdf")), .asset)
        XCTAssertNil(FileTree.kind(of: root.appendingPathComponent("d.txt")))
    }

    /// The Library lists exactly what the editor can render inline: an asset
    /// kind the resolver cannot embed has no business showing up as a row.
    func testPreviewableSetMatchesTheAssetResolver() {
        for ext in FileTree.previewableExtensions {
            XCTAssertNotNil(AssetKind(fileExtension: ext), "\(ext) is listed but not resolvable")
        }
    }

    func testOrdering() throws {
        try touch("Zebra.md")
        try touch("apple.md")
        try mkdir("Work")
        try mkdir("archive")

        let nodes = FileTree.children(of: root)
        XCTAssertEqual(nodes.map(\.name), ["archive", "Work", "apple.md", "Zebra.md"])
        XCTAssertEqual(nodes.prefix(2).allSatisfy(\.isDirectory), true)
    }

    func testSkipsHiddenFiles() throws {
        try touch(".secret.md")
        try touch("visible.md")
        XCTAssertEqual(FileTree.children(of: root).map(\.name), ["visible.md"])
    }

    func testMissingDirectoryReturnsEmpty() {
        let missing = root.appendingPathComponent("does-not-exist")
        XCTAssertEqual(FileTree.children(of: missing), [])
    }

    func testAllFilesRecurses() throws {
        try touch("top.md")
        try mkdir("sub")
        try Data().write(to: root.appendingPathComponent("sub/nested.tex"))
        try Data().write(to: root.appendingPathComponent("sub/figure.png"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("sub/deep/deepest.md"))

        // Assets come along, so Quick Open finds them too.
        let names = Set(FileTree.allFiles(in: root).map(\.name))
        XCTAssertEqual(names, ["top.md", "nested.tex", "figure.png", "deepest.md"])
    }

    func testAllFilesRespectsMaxDepth() throws {
        try mkdir("a")
        try Data().write(to: root.appendingPathComponent("a/x.md"))
        // maxDepth 0 only scans the root level, so the nested file is excluded.
        XCTAssertTrue(FileTree.allFiles(in: root, maxDepth: 0).isEmpty)
    }
}
