import XCTest
@testable import ChalkKit

final class CompilePlannerTests: XCTestCase {
    private let tex = URL(fileURLWithPath: "/p/main.tex")

    private func plan(_ file: URL, _ source: String = "", engine: LatexEngineChoice = .automatic,
                      markdown: MarkdownCompilerChoice = .automatic, tools: Set<String>) -> Result<CompileJob, CompilePlanError> {
        CompilePlanner.job(for: file, source: source,
                           settings: CompileSettings(latexEngine: engine, markdownCompiler: markdown),
                           available: tools.contains)
    }

    func testAutomaticPrefersLatexmkWithSynctex() throws {
        let job = try plan(tex, tools: ["latexmk", "pdflatex"]).get()
        XCTAssertEqual(job.plan, .steps([CompileStep("latexmk", ["-synctex=1", "-interaction=nonstopmode", "-file-line-error", "-pdf", "main.tex"])]))
        XCTAssertEqual(job.workingDirectory.path, "/p")
        XCTAssertEqual(job.pdf.path, "/p/main.pdf")
        XCTAssertEqual(job.notes, [])
    }

    func testMagicProgramPicksTheLatexmkSwitch() throws {
        let job = try plan(tex, "% !TEX TS-program = XeLaTeX\n\\documentclass{article}", tools: ["latexmk"]).get()
        guard case let .steps(steps) = job.plan else { return XCTFail("expected steps") }
        XCTAssertTrue(steps[0].arguments.contains("-xelatex"))
    }

    func testAutomaticFallsBackToDirectPassesWithoutLatexmk() throws {
        let job = try plan(tex, "% !TEX program = lualatex\n", tools: ["lualatex", "pdflatex"]).get()
        XCTAssertEqual(job.plan, .latexPasses(program: .lualatex, file: "main.tex"))
        XCTAssertEqual(job.notes.count, 1)
    }

    func testAutomaticFallsBackToTectonicLast() throws {
        let job = try plan(tex, tools: ["tectonic"]).get()
        guard case let .steps(steps) = job.plan else { return XCTFail("expected steps") }
        XCTAssertEqual(steps[0].tool, "tectonic")
    }

    func testExplicitEngineMissingIsAnError() {
        XCTAssertEqual(plan(tex, engine: .latexmk, tools: ["pdflatex"]), .failure(.missingTool("latexmk", hint: CompilePlanner.texHint)))
        if case .success = plan(tex, tools: []) { XCTFail("no TeX at all must fail") }
    }

    private let md = URL(fileURLWithPath: "/n/note.md")
    private let qmd = URL(fileURLWithPath: "/n/report.qmd")
    private let quartoRender = { (name: String) in CompilePlan.steps([CompileStep("quarto", ["render", name, "--to", "pdf"])]) }

    func testPandocRunsCiteprocWithAnAvailablePdfEngine() throws {
        let job = try plan(md, tools: ["pandoc", "pdflatex"]).get()
        XCTAssertEqual(job.plan, .steps([CompileStep("pandoc", ["note.md", "-s", "-o", "note.pdf", "--pdf-engine=pdflatex", "--citeproc"])]))
        XCTAssertEqual(job.notes, ["xelatex not found: pandoc uses pdflatex."])
    }

    func testPandocNumbersSectionsWhenTheHeaderAsks() throws {
        let source = "---\ntitle: x\nformat:\n  pdf:\n    number-sections: true\n---\n# A\n"
        guard case let .steps(steps) = try plan(md, source, tools: ["pandoc", "xelatex"]).get().plan else { return XCTFail() }
        XCTAssertEqual(steps[0].arguments.last, "--number-sections")
        // Only the header counts.
        guard case let .steps(body) = try plan(md, "# A\nnumber-sections: true\n", tools: ["pandoc", "xelatex"]).get().plan else { return XCTFail() }
        XCTAssertFalse(body[0].arguments.contains("--number-sections"))
    }

    func testAutomaticUsesQuartoForMarkdownWhenInstalled() throws {
        XCTAssertEqual(try plan(md, tools: ["quarto", "pandoc"]).get().plan, quartoRender("note.md"))
        XCTAssertEqual(try plan(qmd, tools: ["quarto"]).get().plan, quartoRender("report.qmd"))
        let fallback = try plan(qmd, tools: ["pandoc", "xelatex"]).get()
        XCTAssertTrue(fallback.notes.first?.contains("cross-references") == true)
    }

    private func plan(_ file: URL, _ source: String, header: String?, markdown: MarkdownCompilerChoice = .automatic,
                      tools: Set<String>) throws -> CompileJob {
        try CompilePlanner.job(for: file, source: source,
                               settings: CompileSettings(markdownCompiler: markdown, defaultMarkdownHeader: header),
                               available: tools.contains).get()
    }

    func testAHeaderlessFileCompilesAStagedCopyWithTheDefaultHeader() throws {
        let job = try plan(md, "# A\n", header: "format:\n  pdf:\n    number-sections: true", tools: ["quarto"])
        XCTAssertEqual(job.staged, StagedSource(fileName: "note.chalk-render.md",
                                                contents: "---\nformat:\n  pdf:\n    number-sections: true\n---\n\n# A\n"))
        XCTAssertEqual(job.plan, .steps([CompileStep("quarto", ["render", "note.chalk-render.md", "--to", "pdf", "--output", "note.pdf"])]))
        XCTAssertEqual(job.pdf.lastPathComponent, "note.pdf")

        let pandoc = try plan(qmd, "# A\n", header: "number-sections: true", markdown: .pandoc, tools: ["pandoc", "xelatex"])
        guard case let .steps(steps) = pandoc.plan else { return XCTFail() }
        XCTAssertEqual(steps[0].arguments.first, "report.chalk-render.qmd")
        XCTAssertEqual(steps[0].arguments[3], "report.pdf")
        XCTAssertTrue(steps[0].arguments.contains("--number-sections"), "the default header's numbering reaches pandoc")
    }

    func testAFileWithItsOwnHeaderOrNoDefaultIsCompiledAsIs() throws {
        let own = try plan(md, "---\ntitle: x\n---\n# A\n", header: "number-sections: true", tools: ["quarto"])
        XCTAssertNil(own.staged)
        XCTAssertEqual(own.plan, quartoRender("note.md"))
        XCTAssertNil(try plan(md, "# A\n", header: nil, tools: ["quarto"]).staged)
        XCTAssertNil(try plan(md, "# A\n", header: "  \n", tools: ["quarto"]).staged, "a blank default is off")
        XCTAssertNil(try plan(tex, "x", header: "number-sections: true", tools: ["latexmk"]).staged, "LaTeX never")
    }

    func testFencing() {
        XCTAssertEqual(MarkdownFrontMatter.fenced("title: x\n"), "---\ntitle: x\n---\n")
        XCTAssertEqual(MarkdownFrontMatter.fenced("---\ntitle: x\n---"), "---\ntitle: x\n---\n")
        XCTAssertEqual(MarkdownFrontMatter.fenced(" \n"), "")
    }

    func testTheUserCanForceEitherCompiler() throws {
        guard case let .steps(steps) = try plan(qmd, markdown: .pandoc, tools: ["quarto", "pandoc", "xelatex"]).get().plan else { return XCTFail() }
        XCTAssertEqual(steps[0].tool, "pandoc")
        XCTAssertEqual(try plan(md, markdown: .quarto, tools: ["quarto"]).get().plan, quartoRender("note.md"))
        XCTAssertEqual(plan(md, markdown: .quarto, tools: ["pandoc", "xelatex"]),
                       .failure(.missingTool("quarto", hint: CompilePlanner.quartoHint)))
    }

    func testUnsupportedExtension() {
        XCTAssertEqual(plan(URL(fileURLWithPath: "/a.txt"), tools: []), .failure(.unsupportedFile("a.txt")))
    }

    func testPassDecisions() {
        XCTAssertEqual(LatexPasses.bibliographyTool(aux: nil, bcfExists: true), "biber")
        XCTAssertEqual(LatexPasses.bibliographyTool(aux: "\\bibstyle{plain}\n\\bibdata{refs}", bcfExists: false), "bibtex")
        XCTAssertNil(LatexPasses.bibliographyTool(aux: "\\relax", bcfExists: false))
        XCTAssertTrue(LatexPasses.needsRerun(output: "LaTeX Warning: Label(s) may have changed. Rerun to get cross-references right."))
        XCTAssertFalse(LatexPasses.needsRerun(output: "Output written on main.pdf (1 page)."))
    }
}

final class CompileLogTests: XCTestCase {
    func testFileLineErrorsComeFirstAndDeduplicated() {
        let out = """
        LaTeX Warning: Reference `fig:a' on page 1 undefined on input line 12.
        ./sections/intro.tex:7: Undefined control sequence.
        l.7 \\foo
        ./sections/intro.tex:7: Undefined control sequence.
        """
        XCTAssertEqual(CompileLog.issues(in: out), [
            CompileIssue(severity: .error, file: "sections/intro.tex", line: 7, message: "Undefined control sequence."),
            CompileIssue(severity: .warning, file: nil, line: 12, message: "Reference `fig:a' on page 1 undefined"),
        ])
    }

    func testBareErrorTakesItsLineFromTheLMarker() {
        let out = "! Missing $ inserted.\n<inserted text>\n                $\nl.42 x^2\n"
        XCTAssertEqual(CompileLog.issues(in: out), [CompileIssue(severity: .error, file: nil, line: 42, message: "Missing $ inserted.")])
    }

    func testTectonicLines() {
        XCTAssertEqual(CompileLog.issues(in: "error: main.tex:3: Undefined control sequence"), [
            CompileIssue(severity: .error, file: "main.tex", line: 3, message: "Undefined control sequence"),
        ])
    }
}

final class SyncTeXTests: XCTestCase {
    func testParsesTheFirstViewRecord() {
        let out = """
        This is SyncTeX command line utility, version 1.5
        SyncTeX result begin
        Output:/p/main.pdf
        Page:2
        x:133.77
        y:134.77
        h:72.0
        v:150.5
        W:343.71
        H:9.96
        before:
        Output:/p/main.pdf
        Page:3
        SyncTeX result end
        """
        XCTAssertEqual(SyncTeX.parseView(out), SyncTeX.PDFLocation(page: 2, x: 72.0, y: 150.5, width: 343.71, height: 9.96))
    }

    func testParsesEditAndStandardizesTheInput() {
        let out = "SyncTeX result begin\nOutput:main.pdf\nInput:/p/./sections/intro.tex\nLine:12\nColumn:-1\nSyncTeX result end\n"
        XCTAssertEqual(SyncTeX.parseEdit(out), SyncTeX.SourceLocation(input: "/p/sections/intro.tex", line: 12))
        XCTAssertNil(SyncTeX.parseEdit("SyncTeX ERROR: no result"))
    }

    func testArguments() {
        XCTAssertEqual(SyncTeX.viewArguments(line: 5, input: "/p/a.tex", pdf: "/p/main.pdf"), ["view", "-i", "5:0:/p/a.tex", "-o", "/p/main.pdf"])
        XCTAssertEqual(SyncTeX.editArguments(page: 1, x: 10, y: 20.5, pdf: "/p/main.pdf"), ["edit", "-o", "1:10.0:20.5:/p/main.pdf"])
    }
}

final class ToolLocatorTests: XCTestCase {
    func testSearchPathPutsStandardFoldersFirstAndDedupes() {
        let path = ToolLocator.searchPath(loginShellPath: "/Users/x/anaconda3/bin:/usr/bin::/opt/homebrew/bin")
        XCTAssertEqual(path.first, "/Library/TeX/texbin")
        XCTAssertEqual(path.last, "/Users/x/anaconda3/bin")
        XCTAssertEqual(path.filter { $0 == "/usr/bin" }.count, 1)
    }

    /// Runs the real login shell: a quoting slip here returned nil on every
    /// Mac, and pandoc in a conda folder was never found.
    func testReadsTheLoginShellPath() throws {
        let path = try XCTUnwrap(ToolLocator.readLoginShellPath(timeout: 10))
        XCTAssertTrue(path.split(separator: ":").contains("/usr/bin"), path)
    }

    func testLocatePrefersAnExecutableOverride() {
        let locator = ToolLocator(searchPath: ["/a", "/b"], isExecutable: { ["/b/pandoc", "/custom/pandoc"].contains($0) })
        XCTAssertEqual(locator.locate("pandoc"), "/b/pandoc")
        XCTAssertEqual(locator.locate("pandoc", override: "/custom/pandoc"), "/custom/pandoc")
        XCTAssertNil(locator.locate("pandoc", override: "/missing/pandoc"))
        XCTAssertNil(locator.locate("quarto"))
    }
}

final class CompileCoalescerTests: XCTestCase {
    func testFoldsRequestsDuringARunIntoOneRerun() {
        let c = CompileCoalescer()
        XCTAssertEqual(c.request("/p/main.tex"), .start)
        XCTAssertEqual(c.request("/p/main.tex"), .queued)
        XCTAssertEqual(c.request("/p/main.tex"), .queued)
        XCTAssertEqual(c.request("/p/slides.tex"), .start)
        XCTAssertTrue(c.finished("/p/main.tex"))
        XCTAssertTrue(c.isRunning("/p/main.tex"))
        XCTAssertFalse(c.finished("/p/main.tex"))
        XCTAssertFalse(c.isRunning("/p/main.tex"))
    }
}

final class StagedSourceRunnerTests: XCTestCase {
    /// `cat` stands in for the compiler: it proves the staged copy exists while the steps run,
    /// and the copy must be gone afterwards.
    func testTheStagedCopyExistsDuringTheRunAndNotAfter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chalk-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = CompileJob(
            source: dir.appendingPathComponent("note.md"), workingDirectory: dir,
            pdf: dir.appendingPathComponent("note.pdf"),
            plan: .steps([CompileStep("cat", ["note.chalk-render.md"])]), notes: [],
            staged: StagedSource(fileName: "note.chalk-render.md", contents: "---\ntitle: staged\n---\n# A\n"))
        let outcome = CompileProcessRunner(locator: ToolLocator(searchPath: ["/bin", "/usr/bin"])).run(job)
        XCTAssertTrue(outcome.succeeded, outcome.log)
        XCTAssertTrue(outcome.log.contains("title: staged"), outcome.log)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("note.chalk-render.md").path))
    }
}

/// Runs the real tools when this machine has them; skipped otherwise.
final class CompileProcessRunnerTests: XCTestCase {
    func testCompilesAMultiFileProjectAndSyncsBothWays() throws {
        let locator = ToolLocator(searchPath: ToolLocator.standardDirectories)
        let available = { locator.locate($0) != nil }
        try XCTSkipUnless(available("pdflatex") && available("synctex"), "no TeX Live on this machine")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chalk-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sections"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let main = dir.appendingPathComponent("main.tex")
        try "\\documentclass{article}\n\\begin{document}\n\\input{sections/intro}\n\\end{document}\n".write(to: main, atomically: true, encoding: .utf8)
        try "Hello from the intro.\n\nSecond paragraph.\n".write(to: dir.appendingPathComponent("sections/intro.tex"), atomically: true, encoding: .utf8)

        let job = try CompilePlanner.job(for: main, source: "", settings: CompileSettings(latexEngine: .direct), available: available).get()
        let outcome = CompileProcessRunner(locator: locator, timeout: 120).run(job)
        XCTAssertTrue(outcome.succeeded, outcome.log)
        XCTAssertEqual(outcome.pdf?.path, dir.appendingPathComponent("main.pdf").path)

        let synctex = try XCTUnwrap(locator.locate("synctex"))
        func run(_ args: [String]) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: synctex)
            p.arguments = args
            p.currentDirectoryURL = dir
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let intro = dir.appendingPathComponent("sections/intro.tex").standardizedFileURL.path
        let hit = try XCTUnwrap(SyncTeX.parseView(try run(SyncTeX.viewArguments(line: 3, input: intro, pdf: "main.pdf"))))
        XCTAssertEqual(hit.page, 1)
        let back = try XCTUnwrap(SyncTeX.parseEdit(try run(SyncTeX.editArguments(page: hit.page, x: hit.x + 1, y: hit.y - 1, pdf: "main.pdf"))))
        XCTAssertEqual(URL(fileURLWithPath: back.input).resolvingSymlinksInPath().path, URL(fileURLWithPath: intro).resolvingSymlinksInPath().path)
        XCTAssertEqual(back.line, 3)
    }
}
