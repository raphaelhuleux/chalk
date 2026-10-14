import XCTest
@testable import ChalkKit

/// Parity guard: the Swift header scanner must agree with editor-core's
/// parser about the real bundled snippet file. If a new snippet syntax lands
/// in latex.hsnips that the scanner misreads, these break.
final class HSnipsCatalogTests: XCTestCase {
    /// Five `deletingLastPathComponent()` hops (file -> ChalkKitTests ->
    /// Tests -> ChalkKit -> ios -> repo root), as in PaletteParityTests.
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func bundledSnippets() throws -> [BuiltinSnippet] {
        let url = repoRoot().appendingPathComponent("packages/editor-core/assets/latex.hsnips")
        return HSnipsCatalog.scan(try String(contentsOf: url))
    }

    func testScansAllBundledSnippets() throws {
        // 242 = `grep -c '^snippet' latex.hsnips`; update when defaults change.
        XCTAssertEqual(try bundledSnippets().count, 242)
    }

    func testSuperscriptSnippet() throws {
        // Math-only: `^{}` is invalid outside math, so unlike the display-math
        // triggers this one must not fire in prose.
        let superscript = try XCTUnwrap(bundledSnippets().first { $0.key == ";;" })
        XCTAssertEqual(superscript.description, "Superscript")
        XCTAssertFalse(superscript.options.isRegex)
        XCTAssertTrue(superscript.options.autoExpand)
        XCTAssertEqual(superscript.options.mode, .math)
        XCTAssertEqual(superscript.replacement, "^{$0}")
    }

    func testDisplayMathSnippetStillFiresAnywhere() throws {
        // `;$` opens a math block, so it has to work from prose.
        let display = try XCTUnwrap(bundledSnippets().first { $0.key == ";$" })
        XCTAssertEqual(display.options.mode, .any)
        XCTAssertTrue(display.options.autoExpand)
    }

    func testTextSnippetIsMathOnlyAndWholeWord() throws {
        // `te` (Tab-only, same body) was removed as redundant; `text` is the
        // survivor. Whole-word, so it does not fire mid-identifier.
        let text = try XCTUnwrap(bundledSnippets().first { $0.key == "text" })
        XCTAssertEqual(text.options.mode, .math)
        XCTAssertTrue(text.options.autoExpand)
        XCTAssertTrue(text.options.wholeWord)
        XCTAssertEqual(text.description, "text")
    }

    func testReadsAFlaglessSnippetAsManual() {
        // The `A`-less form still has to parse as Tab-only, whatever the
        // bundled file currently happens to contain.
        let content = """
        snippet aa "manual"
        x
        endsnippet
        """
        XCTAssertFalse(HSnipsCatalog.scan(content)[0].options.autoExpand)
    }

    func testCapturesSectionHeaders() throws {
        let snippets = try bundledSnippets()
        XCTAssertEqual(snippets.first { $0.key == ";m" }?.section, "Greek alphabet")
        XCTAssertEqual(snippets.first { $0.key == "pmat" }?.section, "Linear algebra")
        XCTAssertEqual(snippets.first { $0.key == "case" }?.section, "Environments")
        // Every bundled snippet lands in a section; an unsectioned one would
        // fall through to its own row in Settings.
        XCTAssertTrue(snippets.allSatisfy { !$0.section.isEmpty })
    }

    func testOnlyRulerDelimitedCommentsAreSections() {
        // The file carries ordinary `# …` comments (ordering notes,
        // `# chalk-disable:`). Only a title between two `###` rulers counts,
        // otherwise a note would silently rename the section under it.
        let content = """
        ##############################################################################
        # Real Section
        ##############################################################################
        snippet aa "first" A
        x
        endsnippet

        # just a note, not a section
        snippet bb "second" A
        y
        endsnippet
        """
        let scanned = HSnipsCatalog.scan(content)
        XCTAssertEqual(scanned.map(\.section), ["Real Section", "Real Section"])
    }

    func testRegexSnippetKeyIsRawSource() throws {
        let squared = try XCTUnwrap(bundledSnippets().first { $0.key == "([ ]*)sr" })
        XCTAssertTrue(squared.options.isRegex)
        XCTAssertTrue(squared.options.autoExpand)
        XCTAssertEqual(squared.description, "squared")
    }

    func testExtractsBodiesWithCaptureRewriting() throws {
        let bar = try XCTUnwrap(bundledSnippets().first { $0.key == "([a-gi-zA-Z])bar" })
        // Mirrors editor-core: `rv = m[1]` becomes #1, so a fork of this row
        // inherits text that actually works.
        XCTAssertEqual(bar.replacement, "\\bar{#1}")
        XCTAssertEqual(bar.options.mode, .math)
    }

    func testExtractsMultiLineBodies() throws {
        let display = try XCTUnwrap(bundledSnippets().first { $0.key == "dm" })
        XCTAssertEqual(display.replacement, "\\begin{align}\n$0\n\\end{align}")
    }

    func testSkipsGlobalBlocksAndBodies() {
        let content = """
        global
        function math(context) { return true; }
        endglobal
        context math(context)
        snippet aa "first" A
        snippet-looking body line
        endsnippet
        snippet bb "second"
        body
        endsnippet
        """
        let scanned = HSnipsCatalog.scan(content)
        XCTAssertEqual(scanned.map(\.key), ["aa", "bb"])
        XCTAssertEqual(scanned[0].options.mode, .math)
        XCTAssertNotEqual(scanned[1].options.mode, .math)  // context consumed by `aa`
    }

    func testReadsWordBoundaryAndLineStartFlags() {
        let content = """
        snippet aa "word" Aw
        x
        endsnippet
        snippet bb "line" Ab
        y
        endsnippet
        """
        let scanned = HSnipsCatalog.scan(content)
        XCTAssertTrue(scanned[0].options.wholeWord)
        XCTAssertFalse(scanned[0].options.lineStart)
        XCTAssertFalse(scanned[1].options.wholeWord)
        XCTAssertTrue(scanned[1].options.lineStart)
    }

    func testReadsInvertedMathContext() {
        let content = """
        context !math(context)
        snippet aa "prose" A
        x
        endsnippet
        """
        XCTAssertEqual(HSnipsCatalog.scan(content)[0].options.mode, .text)
    }

    func testStripsNonCaptureJavaScript() {
        let content = """
        snippet aa "x" A
        value: ``rv = 1 + 1``
        endsnippet
        """
        XCTAssertEqual(HSnipsCatalog.scan(content)[0].replacement, "value: ")
    }
}
