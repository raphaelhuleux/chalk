import Foundation

/// What a file compiles as, from its extension.
public enum CompileSource: Equatable, Sendable {
    case latex, markdown, quarto

    public init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "tex": self = .latex
        case "md", "markdown", "mdown": self = .markdown
        case "qmd": self = .quarto
        default: return nil
        }
    }
}

/// How `.tex` files are typeset (Settings > Compile).
public enum LatexEngineChoice: String, CaseIterable, Sendable {
    /// latexmk when installed, else the TeX program run directly, else tectonic.
    case automatic
    case latexmk
    case tectonic
    /// pdflatex/xelatex/lualatex run by Chalk, with bibtex or biber and
    /// reruns decided between passes.
    case direct

    public var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .latexmk: return "latexmk"
        case .tectonic: return "Tectonic"
        case .direct: return "TeX program directly"
        }
    }
}

/// What compiles .md and .qmd files (Settings > Compile).
public enum MarkdownCompilerChoice: String, CaseIterable, Sendable {
    /// Quarto when installed: its cross-references, theorem blocks and
    /// numbering match what the editor previews. pandoc otherwise.
    case automatic
    case quarto
    /// Plain pandoc with citeproc: citations and numbered sections, but no
    /// Quarto cross-references.
    case pandoc

    public var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .quarto: return "Quarto"
        case .pandoc: return "pandoc"
        }
    }
}

/// The YAML header of a Markdown file, read only for what pandoc needs as flags.
public enum MarkdownFrontMatter {
    private static let numberSections = LatexRoot.regex(
        #"^\s*(?:number-sections|numbersections)\s*:\s*true\s*$"#, [.anchorsMatchLines])

    /// The text between a leading `---` line and the next `---` or `...` line, or nil.
    public static func header(of source: String) -> String? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let end = lines.dropFirst().firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t == "---" || t == "..."
        }) else { return nil }
        return lines[1..<end].joined(separator: "\n")
    }

    /// `yaml` as a front-matter block: trimmed, fenced with `---` unless it already is, empty
    /// when there is nothing in it.
    public static func fenced(_ yaml: String) -> String {
        let body = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "" }
        return body.hasPrefix("---") ? body + "\n" : "---\n\(body)\n---\n"
    }

    private static let pdfEngineKey = LatexRoot.regex(
        #"^\s*pdf-engine\s*:\s*([A-Za-z]+)\s*$"#, [.anchorsMatchLines])

    private static let bibliographyKey = LatexRoot.regex(
        #"^\s*(?:bibliography|references)\s*:"#, [.anchorsMatchLines])

    /// The header names a bibliography (or inline references) for citeproc to resolve.
    public static func hasBibliography(_ source: String) -> Bool {
        guard let header = header(of: source) else { return false }
        return bibliographyKey.firstMatch(in: header, range: NSRange(location: 0, length: (header as NSString).length)) != nil
    }

    /// `pdf-engine:` from the header (Quarto reads it; pandoc only takes it as a flag), or nil.
    public static func pdfEngine(_ source: String) -> String? {
        guard let header = header(of: source) else { return nil }
        let ns = header as NSString
        guard let m = pdfEngineKey.firstMatch(in: header, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// `number-sections: true` (Quarto's spelling, at any depth) or pandoc's `numbersections: true`.
    public static func wantsNumberedSections(_ source: String) -> Bool {
        guard let header = header(of: source) else { return false }
        return numberSections.firstMatch(in: header, range: NSRange(location: 0, length: (header as NSString).length)) != nil
    }
}

/// The TeX program, from a `% !TEX program = …` magic comment; pdflatex
/// otherwise.
public enum TexProgram: String, CaseIterable, Sendable {
    case pdflatex, xelatex, lualatex

    private static let magic = LatexRoot.regex(#"^\s*%\s*!\s*TEX\s+(?:TS-)?program\s*=\s*(\w+)"#, [.caseInsensitive, .anchorsMatchLines])

    public static func magic(in source: String) -> TexProgram? {
        let ns = source as NSString
        guard let m = magic.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return TexProgram(rawValue: ns.substring(with: m.range(at: 1)).lowercased())
    }

    /// latexmk's switch for this program.
    var latexmkFlag: String {
        switch self {
        case .pdflatex: return "-pdf"
        case .xelatex: return "-xelatex"
        case .lualatex: return "-lualatex"
        }
    }
}

/// One process to run: a tool name (resolved by `ToolLocator`) and its arguments.
public struct CompileStep: Equatable, Sendable {
    public var tool: String
    public var arguments: [String]

    public init(_ tool: String, _ arguments: [String]) {
        self.tool = tool
        self.arguments = arguments
    }
}

public enum CompilePlan: Equatable, Sendable {
    /// Fixed steps in order; a non-zero exit stops the run.
    case steps([CompileStep])
    /// TeX program passes with the bibliography tool and reruns chosen
    /// between passes (`LatexPasses`), for machines without latexmk.
    case latexPasses(program: TexProgram, file: String)
}

/// A planned compile: run `plan` in `workingDirectory`, expect `pdf`.
public struct CompileJob: Equatable, Sendable {
    public var source: URL
    public var workingDirectory: URL
    public var pdf: URL
    public var plan: CompilePlan
    /// Shown in the compile log before the output (a fallback that was taken).
    public var notes: [String]
    /// A copy of the source the runner writes beside it before the steps and removes after:
    /// a Markdown file without a YAML header, with the default header prepended. The user's
    /// file is never touched.
    public var staged: StagedSource?
}

public struct StagedSource: Equatable, Sendable {
    /// In the working directory, so relative images and bibliographies still resolve.
    public var fileName: String
    public var contents: String
}

public struct CompileSettings: Equatable, Sendable {
    public var latexEngine: LatexEngineChoice
    /// pandoc's `--pdf-engine`.
    public var pandocPdfEngine: String
    public var markdownCompiler: MarkdownCompilerChoice
    /// YAML given to a .md/.qmd file that has no header of its own; nil when off.
    public var defaultMarkdownHeader: String?

    public init(latexEngine: LatexEngineChoice = .automatic, pandocPdfEngine: String = "xelatex",
                markdownCompiler: MarkdownCompilerChoice = .automatic, defaultMarkdownHeader: String? = nil) {
        self.latexEngine = latexEngine
        self.pandocPdfEngine = pandocPdfEngine
        self.markdownCompiler = markdownCompiler
        self.defaultMarkdownHeader = defaultMarkdownHeader
    }
}

public enum CompilePlanError: Error, Equatable, CustomStringConvertible {
    case missingTool(String, hint: String)
    case unsupportedFile(String)

    public var description: String {
        switch self {
        case let .missingTool(tool, hint): return "\(tool) was not found. \(hint)"
        case let .unsupportedFile(name): return "\(name) is not a .tex, .md or .qmd file."
        }
    }
}

public enum CompilePlanner {
    static let texHint = "Install MacTeX (tug.org/mactex) or set the tool's path in Settings > Compile."
    static let pandocHint = "Install pandoc (pandoc.org) or set its path in Settings > Compile."
    static let quartoHint = "Install Quarto (quarto.org), or choose pandoc as the Markdown compiler in Settings > Compile."

    /// The job for `file` (for LaTeX, the root already resolved by
    /// `LatexRoot`). `source` is the file's text, read for magic comments.
    /// `available` says whether a tool name resolves on this machine.
    public static func job(
        for file: URL,
        source: String,
        settings: CompileSettings,
        available: (String) -> Bool
    ) -> Result<CompileJob, CompilePlanError> {
        guard let kind = CompileSource(fileExtension: file.pathExtension) else {
            return .failure(.unsupportedFile(file.lastPathComponent))
        }
        let dir = file.deletingLastPathComponent()
        let name = file.lastPathComponent
        let pdf = file.deletingPathExtension().appendingPathExtension("pdf")
        func job(_ plan: CompilePlan, _ notes: [String] = [], staged: StagedSource? = nil) -> Result<CompileJob, CompilePlanError> {
            .success(CompileJob(source: file, workingDirectory: dir, pdf: pdf, plan: plan, notes: notes, staged: staged))
        }

        switch kind {
        case .latex:
            let program = TexProgram.magic(in: source) ?? .pdflatex
            let latexmk = CompileStep("latexmk", [
                "-synctex=1", "-interaction=nonstopmode", "-file-line-error", program.latexmkFlag, name,
            ])
            let tectonic = CompileStep("tectonic", ["--synctex", "--keep-logs", "--keep-intermediates", name])
            switch settings.latexEngine {
            case .latexmk:
                return available("latexmk") ? job(.steps([latexmk])) : .failure(.missingTool("latexmk", hint: texHint))
            case .tectonic:
                return available("tectonic") ? job(.steps([tectonic])) : .failure(.missingTool("tectonic", hint: "Install it with `brew install tectonic`."))
            case .direct:
                return available(program.rawValue)
                    ? job(.latexPasses(program: program, file: name))
                    : .failure(.missingTool(program.rawValue, hint: texHint))
            case .automatic:
                if available("latexmk") { return job(.steps([latexmk])) }
                if available(program.rawValue) {
                    return job(.latexPasses(program: program, file: name), ["latexmk not found: running \(program.rawValue) directly."])
                }
                if available("tectonic") { return job(.steps([tectonic]), ["No TeX Live found: using tectonic."]) }
                return .failure(.missingTool(program.rawValue, hint: texHint))
            }

        case .markdown, .quarto:
            var notes: [String] = []
            // A file without a header compiles from a staged copy that carries the default one.
            var input = name
            var source = source
            var staged: StagedSource?
            if MarkdownFrontMatter.header(of: source) == nil,
               let header = settings.defaultMarkdownHeader.map(MarkdownFrontMatter.fenced), !header.isEmpty {
                let stem = file.deletingPathExtension().lastPathComponent
                input = "\(stem).chalk-render.\(file.pathExtension)"
                source = header + "\n" + source
                staged = StagedSource(fileName: input, contents: source)
                notes.append("No YAML header: compiled with the default header from Settings > Compile.")
            }
            // Quarto names the PDF after its input; a staged copy must still produce the file's own.
            let quarto = CompileStep("quarto", ["render", input, "--to", "pdf"]
                + (staged == nil ? [] : ["--output", pdf.lastPathComponent]))
            switch settings.markdownCompiler {
            case .quarto:
                guard available("quarto") else { return .failure(.missingTool("quarto", hint: quartoHint)) }
                return job(.steps([quarto]), notes, staged: staged)
            case .automatic where available("quarto"):
                return job(.steps([quarto]), notes, staged: staged)
            case .automatic:
                if kind == .quarto { notes.append("quarto not found: compiled with pandoc, so Quarto cross-references and code cells were not processed.") }
            case .pandoc:
                if kind == .quarto { notes.append("Compiled with pandoc (Settings > Compile): Quarto cross-references and code cells are not processed.") }
            }
            guard available("pandoc") else { return .failure(.missingTool("pandoc", hint: pandocHint)) }
            // pandoc's PDF path needs a TeX engine of its own: the header's `pdf-engine:` first
            // (a header built on a pdflatex font package breaks under xelatex), then Settings.
            let wanted = MarkdownFrontMatter.pdfEngine(source) ?? settings.pandocPdfEngine
            let engine = ([wanted] + ["xelatex", "lualatex", "pdflatex", "tectonic"]).first(where: available)
            guard let engine else { return .failure(.missingTool(wanted, hint: texHint)) }
            if engine != wanted { notes.append("\(wanted) not found: pandoc uses \(engine).") }
            // citeproc only with a bibliography: without one it takes Quarto's `@eq-…` references
            // for citations, and with `link-citations` emits LaTeX that does not compile. pandoc
            // ignores Quarto's nested `number-sections`, so it goes in as a flag.
            var args = [input, "-s", "-o", pdf.lastPathComponent, "--pdf-engine=\(engine)"]
            if MarkdownFrontMatter.hasBibliography(source) { args.append("--citeproc") }
            if MarkdownFrontMatter.wantsNumberedSections(source) { args.append("--number-sections") }
            return job(.steps([CompileStep("pandoc", args)]), notes, staged: staged)
        }
    }
}

/// Decisions between TeX program passes when Chalk runs them itself.
public enum LatexPasses {
    /// Most program passes after the first, bibliography aside.
    public static let maxReruns = 3

    public static func programArguments(file: String) -> [String] {
        ["-synctex=1", "-interaction=nonstopmode", "-file-line-error", file]
    }

    /// biber when biblatex left a `.bcf`, bibtex when the `.aux` names a
    /// `\bibdata`, else none.
    public static func bibliographyTool(aux: String?, bcfExists: Bool) -> String? {
        if bcfExists { return "biber" }
        if aux?.contains("\\bibdata") == true { return "bibtex" }
        return nil
    }

    /// The pass's output asks for another pass (cross-references, labels).
    public static func needsRerun(output: String) -> Bool {
        output.contains("Rerun to get") || output.contains("Label(s) may have changed")
            || output.contains("Please rerun LaTeX") || output.contains("rerun LaTeX")
    }
}
