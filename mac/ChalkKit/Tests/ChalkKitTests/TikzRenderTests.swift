import CoreGraphics
import XCTest
@testable import ChalkKit

final class TikzRenderTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tikz-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// The wire shape editor-core's `TikzResult` reads.
    func testResultEncodesAsTheEditorReadsIt() throws {
        let image = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(TikzRenderResult.image(url: "data:x", width: 12, height: 8))) as? [String: Any]
        XCTAssertEqual(image?["url"] as? String, "data:x")
        XCTAssertEqual(image?["width"] as? Double, 12)
        XCTAssertEqual(image?["height"] as? Double, 8)
        XCTAssertNil(image?["error"])
        let error = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(TikzRenderResult.error("! Oops."))) as? [String: Any]
        XCTAssertEqual(error as? [String: String], ["error": "! Oops."])
        for value in [TikzRenderResult.image(url: "u", width: 1, height: 2), .error("e")] {
            XCTAssertEqual(try JSONDecoder().decode(TikzRenderResult.self, from: JSONEncoder().encode(value)), value)
        }
    }

    func testErrorMessageTakesTheFirstTeXErrorWithItsContext() {
        let log = """
        This is pdfTeX
        ! Undefined control sequence.
        <recently read> \\drwa
        l.5 \\drwa
                   (0,0) -- (1,1);
        ! Emergency stop.
        """
        XCTAssertEqual(TikzRenderService.errorMessage(log: log, timeout: 20), "! Undefined control sequence.\nl.5 \\drwa")
        XCTAssertEqual(TikzRenderService.errorMessage(log: "[chalk] pdflatex stopped after 0 min\n", timeout: 20),
                       "pdflatex took longer than 20 s.")
        XCTAssertEqual(TikzRenderService.errorMessage(log: "", timeout: 20), "pdflatex failed.")
    }

    /// A 72 x 36 pt page is 96 x 48 CSS px, drawn at 3x.
    func testRasterizeSizesThePageInCSSPixels() throws {
        let pdf = scratch.appendingPathComponent("box.pdf")
        var box = CGRect(x: 0, y: 0, width: 72, height: 36)
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: 20, height: 10))
        context.endPDFPage()
        context.closePDF()

        guard case let .image(url, width, height)? = TikzRenderService.rasterize(pdf: pdf) else {
            return XCTFail("no image")
        }
        XCTAssertEqual(width, 96)
        XCTAssertEqual(height, 48)
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,"))
        let png = try XCTUnwrap(Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 288)
        XCTAssertEqual(image.height, 144)
    }

    func testPruneKeepsTheMostRecentlyUsed() throws {
        let fm = FileManager.default
        let total = TikzRenderService.diskLimit + 1
        for i in 0..<total {
            let url = scratch.appendingPathComponent("\(i).json")
            try Data().write(to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(i))], ofItemAtPath: url.path)
        }
        TikzRenderService.pruneDiskCache(scratch)
        let left = try fm.contentsOfDirectory(atPath: scratch.path)
        XCTAssertEqual(left.count, TikzRenderService.diskKeep)
        XCTAssertTrue(left.contains("\(total - 1).json"))
        XCTAssertFalse(left.contains("0.json"))
    }

    func testNoToolsAnswersNil() async {
        let service = TikzRenderService(locator: { nil }, cacheDirectory: nil)
        let result = await service.render(.init(document: "x", workingDirectory: nil))
        XCTAssertNil(result)
    }

    func testMissingPdflatexAnswersNil() async {
        let empty = ToolLocator(searchPath: [scratch.path])
        let service = TikzRenderService(locator: { empty }, cacheDirectory: nil)
        let result = await service.render(.init(document: "x", workingDirectory: nil))
        XCTAssertNil(result)
    }

    // MARK: With TeX installed

    private func texLocator() throws -> ToolLocator {
        let locator = ToolLocator(searchPath: ToolLocator.standardDirectories)
        guard locator.locate("pdflatex") != nil else { throw XCTSkip("pdflatex is not installed") }
        return locator
    }

    private let figure = """
    \\documentclass[border=2pt]{standalone}
    \\usepackage{tikz}
    \\begin{document}
    \\begin{tikzpicture}\\draw[red] (0,0) circle (1);\\end{tikzpicture}
    \\end{document}
    """

    func testTypesetsAndCachesOnDisk() async throws {
        let tools = try texLocator()
        let cache = scratch.appendingPathComponent("cache")
        let service = TikzRenderService(locator: { tools }, cacheDirectory: cache)
        let request = TikzRenderService.Request(document: figure, workingDirectory: scratch)
        guard case let .image(_, width, height)? = await service.render(request) else {
            return XCTFail("no image")
        }
        // A 2 cm circle plus a 2 pt border each side, in CSS px.
        XCTAssertEqual(width, height, accuracy: 0.5)
        XCTAssertEqual(width, (2 / 2.54 * 72 + 4) * 4 / 3, accuracy: 2)
        // Nothing is left in the document's folder but the cache.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), ["cache"])

        // A new service (a relaunch) answers from disk without TeX.
        let relaunched = TikzRenderService(locator: { nil }, cacheDirectory: cache)
        let cached = await relaunched.render(request)
        guard case .image? = cached else { return XCTFail("not cached") }
    }

    func testReportsTheTeXError() async throws {
        let tools = try texLocator()
        let service = TikzRenderService(locator: { tools }, cacheDirectory: nil)
        let broken = figure.replacingOccurrences(of: "\\draw[red]", with: "\\drwa")
        guard case let .error(message)? = await service.render(.init(document: broken, workingDirectory: nil)) else {
            return XCTFail("no error")
        }
        XCTAssertTrue(message.hasPrefix("! Undefined control sequence."), message)
    }
}
