import XCTest
@testable import ChalkKit

/// Listing for the editor's path and citation completion. The editor asks for
/// kinds; the host walks and answers with document-relative paths.
final class WorkspaceListingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    func testListsImagesRelativeToTheDocumentDirectory() throws {
        try touch("figures/plot.png")
        try touch("scan.JPG")
        try touch("notes.md")

        let paths = FileTree.relativePaths(in: root, kinds: [.image])
        XCTAssertEqual(paths.sorted(), ["figures/plot.png", "scan.JPG"])
    }

    func testListsDocumentsAndBibliographiesSeparately() throws {
        try touch("chapters/intro.tex")
        try touch("notes.md")
        try touch("refs.bib")

        XCTAssertEqual(
            FileTree.relativePaths(in: root, kinds: [.document]).sorted(),
            ["chapters/intro.tex", "notes.md"])
        XCTAssertEqual(FileTree.relativePaths(in: root, kinds: [.bib]), ["refs.bib"])
    }

    func testCombinesRequestedKinds() throws {
        try touch("plot.png")
        try touch("notes.md")
        try touch("refs.bib")

        XCTAssertEqual(
            FileTree.relativePaths(in: root, kinds: [.image, .document]).sorted(),
            ["notes.md", "plot.png"])
    }

    func testSkipsHiddenFilesAndUnknownTypes() throws {
        try touch(".secret.png")
        try touch("readme.txt")
        try touch("keep.png")

        XCTAssertEqual(FileTree.relativePaths(in: root, kinds: [.image]), ["keep.png"])
    }

    func testCapsTheResultCount() throws {
        for i in 0..<40 { try touch("f\(i).png") }
        XCTAssertEqual(FileTree.relativePaths(in: root, kinds: [.image], limit: 10).count, 10)
    }

    func testMissingDirectoryReturnsEmpty() {
        let gone = root.appendingPathComponent("nope")
        XCTAssertEqual(FileTree.relativePaths(in: gone, kinds: [.image]), [])
    }

    /// The completion popup must never offer a `.bib` as a document, nor a
    /// bibliography extension leak into the previewable set the asset
    /// resolver is pinned to.
    func testBibliographyIsItsOwnSet() {
        XCTAssertFalse(FileTree.previewableExtensions.contains("bib"))
        XCTAssertFalse(FileTree.editableExtensions.contains("bib"))
        XCTAssertTrue(FileTree.bibliographyExtensions.contains("bib"))
    }
}

/// Cross-seam parity for the listing request. The kinds travel as raw strings
/// over the WKWebView bridge (transport-internal, like resolve-asset — no
/// Codable mirror), so nothing but a test keeps the two vocabularies aligned:
/// rename one side and completion silently returns nothing.
final class WorkspaceKindParityTests: XCTestCase {
    /// `#filePath` is .../mac/ChalkKit/Tests/ChalkKitTests/…; five hops reach
    /// the repo root (same trick as PaletteParityTests).
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testKindsMatchTheTypeScriptUnion() throws {
        let source = try String(
            contentsOf: repoRoot()
                .appendingPathComponent("packages/editor-core/src/editor/workspace-files.ts"))
        guard let range = source.range(of: "export type WorkspaceFileKind = "),
              let end = source[range.upperBound...].firstIndex(of: ";") else {
            return XCTFail("WorkspaceFileKind union not found in workspace-files.ts")
        }
        let names = source[range.upperBound..<end]
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\n\t")) }

        XCTAssertEqual(
            names.sorted(),
            WorkspaceFileKind.allCases.map(\.rawValue).sorted(),
            "Swift WorkspaceFileKind drifted from the TypeScript union")
    }
}
