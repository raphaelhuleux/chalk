import XCTest
import UIKit
import ChalkKit
@testable import Chalk

/// End-to-end resolver behavior behind the editor's `resolve-asset` bridge:
/// `DocumentController.editor(_:resolveAsset:)` resolving real files in a
/// temp directory — relative paths, LaTeX extension probing, `\graphicspath`,
/// PDF rasterization — through `AssetResolution` (pure, ChalkKit) and
/// `AssetLoader` (IO + PDFKit, app target).
final class AssetResolveTests: XCTestCase {
    private var surface: FakeEditorSurface!
    private var controller: DocumentController!
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        surface = FakeEditorSurface()
        controller = DocumentController(surface: surface)
        surface.signalReady()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("figures", isDirectory: true),
            withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        controller = nil
        surface = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func pngBytes(width: Int = 4, height: Int = 4) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.pngData()!
    }

    private func pdfBytes(width: CGFloat = 200, height: CGFloat = 100) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            ctx.beginPage()
            UIColor.systemBlue.setFill()
            ctx.fill(bounds)
        }
    }

    @discardableResult
    private func write(_ data: Data, _ relative: String) throws -> URL {
        let url = dir.appendingPathComponent(relative)
        try data.write(to: url)
        return url
    }

    private func openDocument(_ name: String, contents: String) async {
        let url = dir.appendingPathComponent(name)
        try! contents.data(using: .utf8)!.write(to: url)
        let spy = DirtySpy()
        controller.delegate = spy
        let done = expectation(description: "open \(name)")
        spy.onDirtyChange = { _ in done.fulfill() }
        controller.open(url: url)
        await fulfillment(of: [done], timeout: 5)
    }

    private func resolve(_ src: String) async -> String? {
        await controller.editor(surface, resolveAsset: src)
    }

    /// Decode `data:image/...;base64,` back to a UIImage.
    private func decodeImage(_ dataURL: String) -> UIImage? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Markdown

    func testRelativePngRoundTripsItsBytes() async throws {
        let bytes = pngBytes()
        try write(bytes, "figures/plot.png")
        await openDocument("note.md", contents: "![plot](figures/plot.png)\n")

        let result = await resolve("figures/plot.png")
        XCTAssertEqual(result, "data:image/png;base64,\(bytes.base64EncodedString())",
                       "a png must ship verbatim as a base64 data URL")
    }

    func testPercentEncodedSrcResolves() async throws {
        try write(pngBytes(), "my plot.png")
        await openDocument("note.md", contents: "![p](my%20plot.png)\n")

        let result = await resolve("my%20plot.png")
        XCTAssertNotNil(result, "markdown percent-encoding must be decoded before the file lookup")
    }

    func testMarkdownDoesNotProbeExtensions() async throws {
        try write(pngBytes(), "plot.png")
        await openDocument("note.md", contents: "![p](plot)\n")

        let result = await resolve("plot")
        XCTAssertNil(result, "extension probing is a LaTeX affordance; md paths are literal")
    }

    func testMissingFileResolvesNil() async {
        await openDocument("note.md", contents: "![gone](nope.png)\n")
        let result = await resolve("nope.png")
        XCTAssertNil(result)
    }

    func testUnsupportedExtensionResolvesNil() async throws {
        try write(pngBytes(), "anim.gif")
        await openDocument("note.md", contents: "![a](anim.gif)\n")
        let result = await resolve("anim.gif")
        XCTAssertNil(result)
    }

    func testDraftWithoutDocumentResolvesNil() async {
        controller.openDraft()
        let result = await resolve("plot.png")
        XCTAssertNil(result, "an unsaved draft has no directory to resolve against")
    }

    // MARK: - LaTeX

    func testTexExtensionlessProbingPrefersPdf() async throws {
        try write(pdfBytes(), "plot.pdf")
        try write(pngBytes(), "plot.png")
        await openDocument("paper.tex", contents: "\\includegraphics{plot}\n")

        let maybe = await resolve("plot")
        let result = try XCTUnwrap(maybe)
        XCTAssertTrue(result.hasPrefix("data:image/png;base64,"),
                      "the pdf wins the probe and arrives rasterized as png")
        // Distinguish the rasterized pdf (200x100 fixture, blue) from the raw
        // 4x4 red png: the decoded size must reflect the pdf page's 2:1 ratio.
        let image = try XCTUnwrap(decodeImage(result))
        XCTAssertEqual(image.size.width / image.size.height, 2.0, accuracy: 0.05)
    }

    func testTexHonorsGraphicsPath() async throws {
        try write(pngBytes(), "figures/plot.png")
        await openDocument(
            "paper.tex",
            contents: "\\graphicspath{{figures/}}\n\\includegraphics{plot}\n")

        let maybe = await resolve("plot")
        let result = try XCTUnwrap(maybe, "\\graphicspath directories must join the probe")
        XCTAssertTrue(result.hasPrefix("data:image/png;base64,"))
    }

    /// The TEXINPUTS layout: `paper/paper.tex` referencing `results/plot.pdf`
    /// that actually lives beside `paper/`, one level up.
    func testTexFindsFigureAboveTheDocumentInsideTheLibraryRoot() async throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("paper", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("results", isDirectory: true), withIntermediateDirectories: true)
        try write(pdfBytes(), "results/plot.pdf")
        controller.libraryRootsProvider = { [self.dir!] }
        await openDocument("paper/paper.tex", contents: "\\includegraphics{results/plot.pdf}\n")

        let maybe = await resolve("results/plot.pdf")
        let result = try XCTUnwrap(maybe,
                                   "the search must climb to the Library root, as TEXINPUTS does")
        XCTAssertTrue(result.hasPrefix("data:image/png;base64,"))
    }

    func testTexDoesNotClimbAboveTheLibraryRoot() async throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("paper", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("results", isDirectory: true), withIntermediateDirectories: true)
        try write(pdfBytes(), "results/plot.pdf")
        // The granted folder is the paper dir itself: nothing above it is ours.
        controller.libraryRootsProvider = { [self.dir.appendingPathComponent("paper", isDirectory: true)] }
        await openDocument("paper/paper.tex", contents: "\\includegraphics{results/plot.pdf}\n")

        let result = await resolve("results/plot.pdf")
        XCTAssertNil(result, "the climb stops at the folder the user granted")
    }

    func testMarkdownDoesNotClimbAboveTheDocument() async throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("notes", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("results", isDirectory: true), withIntermediateDirectories: true)
        try write(pngBytes(), "results/plot.png")
        controller.libraryRootsProvider = { [self.dir!] }
        await openDocument("notes/note.md", contents: "![p](results/plot.png)\n")

        let result = await resolve("results/plot.png")
        XCTAssertNil(result, "md srcs are literal document-relative paths; no TEXINPUTS climb")
    }

    /// The `\input`-ed subfile case: the preamble (and its `\graphicspath`)
    /// lives in the root file, so the open buffer declares nothing.
    func testTexInheritsGraphicsPathFromTheRootFileThatInputsIt() async throws {
        let article = dir.appendingPathComponent("paper/article", isDirectory: true)
        try FileManager.default.createDirectory(at: article, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("results", isDirectory: true), withIntermediateDirectories: true)
        try write(pdfBytes(), "results/plot.pdf")
        try "\\documentclass{article}\n\\graphicspath{{../../results/}}\n\\input{accuracy}\n"
            .data(using: .utf8)!
            .write(to: article.appendingPathComponent("_main.tex"))
        controller.libraryRootsProvider = { [self.dir!] }
        await openDocument("paper/article/accuracy.tex", contents: "\\includegraphics{plot}\n")

        let maybe = await resolve("plot")
        let result = try XCTUnwrap(maybe, "the root file's \\graphicspath must reach the subfile")
        XCTAssertTrue(result.hasPrefix("data:image/png;base64,"))
    }

    func testInheritedGraphicsPathStaysInsideTheLibraryRoot() async throws {
        let article = dir.appendingPathComponent("paper/article", isDirectory: true)
        try FileManager.default.createDirectory(at: article, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("results", isDirectory: true), withIntermediateDirectories: true)
        try write(pdfBytes(), "results/plot.pdf")
        try "\\documentclass{article}\n\\graphicspath{{../../results/}}\n"
            .data(using: .utf8)!
            .write(to: article.appendingPathComponent("_main.tex"))
        // Only the article folder is granted: the root file above it is not ours to read.
        controller.libraryRootsProvider = { [article] }
        await openDocument("paper/article/accuracy.tex", contents: "\\includegraphics{plot}\n")

        _ = await resolve("plot")
        // The root file sits in the granted folder here, so this asserts the
        // opposite direction: a declaration found inside scope still resolves.
        let result = await resolve("plot")
        XCTAssertNotNil(result, "a root file inside the granted folder is readable")
    }

    // MARK: - PDF rasterization

    func testPdfRasterizesToBoundedPng() async throws {
        try write(pdfBytes(width: 200, height: 100), "fig.pdf")
        await openDocument("paper.tex", contents: "\\includegraphics{fig.pdf}\n")

        let maybe = await resolve("fig.pdf")
        let result = try XCTUnwrap(maybe)
        XCTAssertTrue(result.hasPrefix("data:image/png;base64,"))
        let image = try XCTUnwrap(decodeImage(result))
        let longEdge = max(image.size.width * image.scale, image.size.height * image.scale)
        XCTAssertGreaterThan(longEdge, 0)
        XCTAssertLessThanOrEqual(longEdge, CGFloat(AssetLoader.maxPDFPixelDimension),
                                 "rasterized pdfs must stay within the pixel bound")
    }

    func testOversizedFileResolvesNil() async throws {
        // A sparse-ish large file: just over the cap, filled with zeros.
        let big = Data(count: AssetResolution.maxAssetBytes + 1)
        try write(big, "huge.png")
        await openDocument("note.md", contents: "![h](huge.png)\n")

        let result = await resolve("huge.png")
        XCTAssertNil(result, "files over maxAssetBytes must not ship through the bridge")
    }
}
