import XCTest
@testable import ChalkKit

/// Pure resolution logic for the image live preview: candidate URLs from a
/// document directory (+ \graphicspath), LaTeX extension probing, MIME
/// mapping, and data-URL assembly. File IO and PDF rasterization live in the
/// app target — here the filesystem is a closure over a Set.
final class AssetResolutionTests: XCTestCase {
    private let docDir = URL(fileURLWithPath: "/notes", isDirectory: true)

    /// fileExists stub backed by a set of absolute paths.
    private func existing(_ paths: Set<String>) -> (URL) -> Bool {
        { paths.contains($0.standardizedFileURL.path) }
    }

    private func resolve(
        _ src: String,
        graphicsPaths: [String] = [],
        probing: Bool = false,
        files: Set<String>
    ) -> (url: URL, kind: AssetKind)? {
        AssetResolution.resolveAsset(
            src: src,
            documentDirectory: docDir,
            graphicsPaths: graphicsPaths,
            allowExtensionProbing: probing,
            fileExists: existing(files)
        )
    }

    // MARK: - Direct resolution

    func testResolvesRelativePathAgainstDocumentDirectory() {
        let r = resolve("figures/plot.png", files: ["/notes/figures/plot.png"])
        XCTAssertEqual(r?.url.path, "/notes/figures/plot.png")
        XCTAssertEqual(r?.kind, .png, "extension .png must map to the png kind")
    }

    func testJpgAndJpegBothMapToJpegKind() {
        XCTAssertEqual(resolve("a.jpg", files: ["/notes/a.jpg"])?.kind, .jpeg)
        XCTAssertEqual(resolve("a.jpeg", files: ["/notes/a.jpeg"])?.kind, .jpeg)
        XCTAssertEqual(resolve("a.JPG", files: ["/notes/a.JPG"])?.kind, .jpeg, "extension match is case-insensitive")
    }

    func testPdfMapsToPdfKind() {
        XCTAssertEqual(resolve("fig.pdf", files: ["/notes/fig.pdf"])?.kind, .pdf)
    }

    func testMissingFileResolvesNil() {
        XCTAssertNil(resolve("figures/plot.png", files: []))
    }

    func testUnsupportedExtensionResolvesNil() {
        XCTAssertNil(resolve("anim.gif", files: ["/notes/anim.gif"]),
                     "gif is out of v1 scope even when the file exists")
    }

    func testEmptyAndWhitespaceSrcResolveNil() {
        XCTAssertNil(resolve("", files: []))
        XCTAssertNil(resolve("   ", files: []))
    }

    func testAbsoluteSrcBypassesBaseDirs() {
        let r = resolve("/elsewhere/fig.png", files: ["/elsewhere/fig.png"])
        XCTAssertEqual(r?.url.path, "/elsewhere/fig.png")
    }

    func testPercentEncodedSrcIsDecoded() {
        let r = resolve("my%20plot.png", files: ["/notes/my plot.png"])
        XCTAssertEqual(r?.url.path, "/notes/my plot.png")
    }

    func testParentRelativePathResolves() {
        let r = resolve("../shared/fig.png", files: ["/shared/fig.png"])
        XCTAssertEqual(r?.url.standardizedFileURL.path, "/shared/fig.png")
    }

    // MARK: - Extension probing (LaTeX \includegraphics{plot})

    func testProbingPrefersPdfThenPngThenJpg() {
        let all: Set<String> = ["/notes/plot.pdf", "/notes/plot.png", "/notes/plot.jpg"]
        XCTAssertEqual(resolve("plot", probing: true, files: all)?.url.path, "/notes/plot.pdf",
                       "pdflatex order: pdf wins when several candidates exist")
        XCTAssertEqual(
            resolve("plot", probing: true, files: ["/notes/plot.png", "/notes/plot.jpg"])?.url.path,
            "/notes/plot.png"
        )
        XCTAssertEqual(
            resolve("plot", probing: true, files: ["/notes/plot.jpg"])?.url.path,
            "/notes/plot.jpg"
        )
    }

    func testNoProbingWhenDisabled() {
        XCTAssertNil(resolve("plot", probing: false, files: ["/notes/plot.png"]),
                     "markdown paths are taken literally; no extension guessing")
    }

    func testExplicitExtensionSkipsProbing() {
        XCTAssertNil(resolve("plot.png", probing: true, files: ["/notes/plot.pdf"]),
                     "an explicit .png must not fall back to the .pdf sibling")
    }

    // MARK: - \graphicspath

    func testGraphicsPathDirsAreSearchedAfterDocumentDirectory() {
        let r = resolve("plot.png", graphicsPaths: ["figures/"], files: ["/notes/figures/plot.png"])
        XCTAssertEqual(r?.url.standardizedFileURL.path, "/notes/figures/plot.png")
    }

    func testDocumentDirectoryWinsOverGraphicsPath() {
        let r = resolve(
            "plot.png",
            graphicsPaths: ["figures/"],
            files: ["/notes/plot.png", "/notes/figures/plot.png"]
        )
        XCTAssertEqual(r?.url.path, "/notes/plot.png")
    }

    func testProbingIsDirMajorAcrossGraphicsPaths() {
        // Doc dir has a png; figures/ has a pdf. Dir-major: the doc dir is
        // exhausted (all extensions) before figures/ is tried.
        let r = resolve(
            "plot",
            graphicsPaths: ["figures/"],
            probing: true,
            files: ["/notes/plot.png", "/notes/figures/plot.pdf"]
        )
        XCTAssertEqual(r?.url.path, "/notes/plot.png")
    }

    func testAbsoluteGraphicsPathEntry() {
        let r = resolve("plot.png", graphicsPaths: ["/assets/"], files: ["/assets/plot.png"])
        XCTAssertEqual(r?.url.standardizedFileURL.path, "/assets/plot.png")
    }

    // MARK: - Ancestor search (workspace root)

    /// The `\includegraphics{results/plot.pdf}` + `TEXINPUTS=../` layout: the
    /// figure tree sits beside the paper folder, not inside it.
    private func resolveInWorkspace(
        _ src: String,
        documentDirectory: URL = URL(fileURLWithPath: "/proj/paper", isDirectory: true),
        workspaceRoot: URL?,
        graphicsPaths: [String] = [],
        probing: Bool = false,
        files: Set<String>
    ) -> (url: URL, kind: AssetKind)? {
        AssetResolution.resolveAsset(
            src: src,
            documentDirectory: documentDirectory,
            graphicsPaths: graphicsPaths,
            allowExtensionProbing: probing,
            workspaceRoot: workspaceRoot,
            fileExists: existing(files)
        )
    }

    func testFindsFigureInAncestorDirectoryUpToWorkspaceRoot() {
        let r = resolveInWorkspace(
            "results/plot.pdf",
            workspaceRoot: URL(fileURLWithPath: "/proj", isDirectory: true),
            files: ["/proj/results/plot.pdf"]
        )
        XCTAssertEqual(r?.url.standardizedFileURL.path, "/proj/results/plot.pdf")
        XCTAssertEqual(r?.kind, .pdf)
    }

    func testAncestorSearchClimbsSeveralLevels() {
        let r = resolveInWorkspace(
            "results/plot.pdf",
            documentDirectory: URL(fileURLWithPath: "/proj/paper/sections", isDirectory: true),
            workspaceRoot: URL(fileURLWithPath: "/proj", isDirectory: true),
            files: ["/proj/results/plot.pdf"]
        )
        XCTAssertEqual(r?.url.standardizedFileURL.path, "/proj/results/plot.pdf")
    }

    func testAncestorSearchStopsAtWorkspaceRoot() {
        XCTAssertNil(
            resolveInWorkspace(
                "results/plot.pdf",
                workspaceRoot: URL(fileURLWithPath: "/proj/paper", isDirectory: true),
                files: ["/proj/results/plot.pdf"]
            ),
            "the root is the document's own directory, so nothing above it may be read"
        )
    }

    func testNoAncestorSearchWithoutAWorkspaceRoot() {
        XCTAssertNil(
            resolveInWorkspace("results/plot.pdf", workspaceRoot: nil, files: ["/proj/results/plot.pdf"]),
            "a document outside every Library Location keeps the document-directory-only scope"
        )
    }

    func testWorkspaceRootOutsideTheDocumentTreeIsIgnored() {
        XCTAssertNil(
            resolveInWorkspace(
                "results/plot.pdf",
                workspaceRoot: URL(fileURLWithPath: "/elsewhere", isDirectory: true),
                files: ["/proj/results/plot.pdf"]
            ),
            "a root that isn't an ancestor grants no extra scope"
        )
    }

    func testDocumentDirectoryWinsOverAncestor() {
        let r = resolveInWorkspace(
            "results/plot.pdf",
            workspaceRoot: URL(fileURLWithPath: "/proj", isDirectory: true),
            files: ["/proj/paper/results/plot.pdf", "/proj/results/plot.pdf"]
        )
        XCTAssertEqual(r?.url.standardizedFileURL.path, "/proj/paper/results/plot.pdf")
    }

    func testGraphicsPathWinsOverAncestor() {
        let r = resolveInWorkspace(
            "plot.pdf",
            workspaceRoot: URL(fileURLWithPath: "/proj", isDirectory: true),
            graphicsPaths: ["figures/"],
            files: ["/proj/paper/figures/plot.pdf", "/proj/plot.pdf"]
        )
        XCTAssertEqual(r?.url.standardizedFileURL.path, "/proj/paper/figures/plot.pdf")
    }

    func testAncestorSearchProbesExtensionsDirMajor() {
        // The nearer ancestor holds a png, the farther one a pdf. Nearest dir
        // wins even though pdf sorts first within a directory.
        let r = resolveInWorkspace(
            "results/plot",
            documentDirectory: URL(fileURLWithPath: "/proj/paper/sections", isDirectory: true),
            workspaceRoot: URL(fileURLWithPath: "/proj", isDirectory: true),
            probing: true,
            files: ["/proj/paper/results/plot.png", "/proj/results/plot.pdf"]
        )
        XCTAssertEqual(r?.url.standardizedFileURL.path, "/proj/paper/results/plot.png")
    }

    func testAbsoluteSrcIgnoresWorkspaceRoot() {
        let r = resolveInWorkspace(
            "/assets/plot.pdf",
            workspaceRoot: URL(fileURLWithPath: "/proj", isDirectory: true),
            files: ["/assets/plot.pdf"]
        )
        XCTAssertEqual(r?.url.standardizedFileURL.path, "/assets/plot.pdf")
    }

    // MARK: - \graphicspath declared in another file

    func testSearchDirsResolveAgainstTheDeclaringFilesOwnDirectory() {
        let main = URL(fileURLWithPath: "/proj/paper/article/_main.tex")
        let dirs = AssetResolution.graphicsSearchDirs(
            declaredIn: [(main, #"\graphicspath{{../../results/}}"#)])
        XCTAssertEqual(dirs.map(\.standardizedFileURL.path), ["/proj/results"],
                       "a root file's entry is relative to the root file, not to the open subfile")
    }

    func testSearchDirsKeepFileAndDeclarationOrderAndDedupe() {
        let main = URL(fileURLWithPath: "/proj/main.tex")
        let other = URL(fileURLWithPath: "/proj/other.tex")
        let dirs = AssetResolution.graphicsSearchDirs(declaredIn: [
            (main, #"\graphicspath{{figures/}{plots/}}"#),
            (other, #"\graphicspath{{plots/}{extra/}}"#),
        ])
        XCTAssertEqual(dirs.map(\.standardizedFileURL.path),
                       ["/proj/figures", "/proj/plots", "/proj/extra"])
    }

    func testSearchDirsIgnoreFilesWithoutGraphicsPath() {
        let dirs = AssetResolution.graphicsSearchDirs(
            declaredIn: [(URL(fileURLWithPath: "/proj/plain.tex"), "\\documentclass{article}")])
        XCTAssertTrue(dirs.isEmpty)
    }

    func testExtraSearchDirsJoinTheProbeAfterTheOwnGraphicsPath() {
        let r = AssetResolution.resolveAsset(
            src: "plot",
            documentDirectory: URL(fileURLWithPath: "/proj/paper/article", isDirectory: true),
            graphicsPaths: [],
            allowExtensionProbing: true,
            extraSearchDirs: [URL(fileURLWithPath: "/proj/results", isDirectory: true)],
            fileExists: existing(["/proj/results/plot.pdf"])
        )
        XCTAssertEqual(r?.url.standardizedFileURL.path, "/proj/results/plot.pdf")
        XCTAssertEqual(r?.kind, .pdf)
    }

    func testOwnGraphicsPathWinsOverAnInheritedOne() {
        let r = AssetResolution.resolveAsset(
            src: "plot.png",
            documentDirectory: URL(fileURLWithPath: "/proj/paper", isDirectory: true),
            graphicsPaths: ["figures/"],
            allowExtensionProbing: false,
            extraSearchDirs: [URL(fileURLWithPath: "/proj/results", isDirectory: true)],
            fileExists: existing(["/proj/paper/figures/plot.png", "/proj/results/plot.png"])
        )
        XCTAssertEqual(r?.url.standardizedFileURL.path, "/proj/paper/figures/plot.png",
                       "the open file's own declaration outranks one inherited from a root file")
    }

    func testInheritedSearchDirWinsOverABlindAncestorClimb() {
        let r = AssetResolution.resolveAsset(
            src: "plot.png",
            documentDirectory: URL(fileURLWithPath: "/proj/paper", isDirectory: true),
            graphicsPaths: [],
            allowExtensionProbing: false,
            workspaceRoot: URL(fileURLWithPath: "/proj", isDirectory: true),
            extraSearchDirs: [URL(fileURLWithPath: "/proj/results", isDirectory: true)],
            fileExists: existing(["/proj/results/plot.png", "/proj/plot.png"])
        )
        XCTAssertEqual(r?.url.standardizedFileURL.path, "/proj/results/plot.png",
                       "a declared directory outranks the TEXINPUTS-style climb")
    }

    // MARK: - Enclosing workspace root

    private func root(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    func testWorkspaceRootIsTheLocationContainingTheDocument() {
        XCTAssertEqual(
            AssetResolution.workspaceRoot(for: root("/proj/paper"), roots: [root("/other"), root("/proj")])?.path,
            "/proj"
        )
    }

    func testDeepestContainingLocationWins() {
        XCTAssertEqual(
            AssetResolution.workspaceRoot(for: root("/proj/paper/sections"), roots: [root("/proj"), root("/proj/paper")])?.path,
            "/proj/paper",
            "the narrowest granted folder bounds the climb"
        )
    }

    func testNoContainingLocationYieldsNoRoot() {
        XCTAssertNil(AssetResolution.workspaceRoot(for: root("/proj/paper"), roots: [root("/elsewhere")]))
    }

    func testLocationMatchIsByPathComponentNotStringPrefix() {
        XCTAssertNil(
            AssetResolution.workspaceRoot(for: root("/proj-old/paper"), roots: [root("/proj")]),
            "/proj must not swallow /proj-old"
        )
    }

    // MARK: - graphicsPaths(inTeX:)

    func testGraphicsPathsParsesSingleDir() {
        XCTAssertEqual(AssetResolution.graphicsPaths(inTeX: #"\graphicspath{{figures/}}"#), ["figures/"])
    }

    func testGraphicsPathsParsesMultipleDirsInOrder() {
        XCTAssertEqual(
            AssetResolution.graphicsPaths(inTeX: #"\graphicspath{{figures/}{plots/}}"#),
            ["figures/", "plots/"]
        )
    }

    func testGraphicsPathsAllowsWhitespaceBetweenGroups() {
        XCTAssertEqual(
            AssetResolution.graphicsPaths(inTeX: "\\graphicspath{ {figures/}\n  {plots/} }"),
            ["figures/", "plots/"]
        )
    }

    func testGraphicsPathsConcatenatesMultipleCommands() {
        let tex = "\\graphicspath{{a/}}\nsome text\n\\graphicspath{{b/}}"
        XCTAssertEqual(AssetResolution.graphicsPaths(inTeX: tex), ["a/", "b/"])
    }

    func testGraphicsPathsIgnoresCommentedCommand() {
        XCTAssertEqual(AssetResolution.graphicsPaths(inTeX: #"% \graphicspath{{x/}}"#), [])
        XCTAssertEqual(
            AssetResolution.graphicsPaths(inTeX: "text % \\graphicspath{{x/}}\n\\graphicspath{{y/}}"),
            ["y/"]
        )
    }

    func testGraphicsPathsEmptyForPlainProse() {
        XCTAssertEqual(AssetResolution.graphicsPaths(inTeX: "no commands here"), [])
    }

    // MARK: - MIME + data URL

    func testMimeTypes() {
        XCTAssertEqual(AssetKind.png.mimeType, "image/png")
        XCTAssertEqual(AssetKind.jpeg.mimeType, "image/jpeg")
        XCTAssertNil(AssetKind.pdf.mimeType, "pdf is rasterized to png by the app layer; it has no direct img MIME")
    }

    func testDataURLAssembly() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(
            AssetResolution.dataURL(mime: "image/png", bytes: bytes),
            "data:image/png;base64,\(bytes.base64EncodedString())"
        )
    }

    func testMaxAssetBytesIs25MB() {
        XCTAssertEqual(AssetResolution.maxAssetBytes, 25 * 1024 * 1024)
    }
}
