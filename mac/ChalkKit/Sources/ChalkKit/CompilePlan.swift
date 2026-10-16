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
}

public struct CompileSettings: Equatable, Sendable {
    public var latexEngine: LatexEngineChoice
    /// pandoc's `--pdf-engine`.
    public var pandocPdfEngine: String

    public init(latexEngine: LatexEngineChoice = .automatic, pandocPdfEngine: String = "xelatex") {
        self.latexEngine = latexEngine
        self.pandocPdfEngine = pandocPdfEngine
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
        func job(_ plan: CompilePlan, _ notes: [String] = []) -> Result<CompileJob, CompilePlanError> {
            .success(CompileJob(source: file, workingDirectory: dir, pdf: pdf, plan: plan, notes: notes))
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
            if kind == .quarto, available("quarto") {
                return job(.steps([CompileStep("quarto", ["render", name, "--to", "pdf"])]))
            }
            guard available("pandoc") else { return .failure(.missingTool("pandoc", hint: pandocHint)) }
            // pandoc's PDF path needs a TeX engine of its own.
            let engine = ([settings.pandocPdfEngine] + ["xelatex", "lualatex", "pdflatex", "tectonic"]).first(where: available)
            guard let engine else { return .failure(.missingTool(settings.pandocPdfEngine, hint: texHint)) }
            var notes: [String] = []
            if kind == .quarto { notes.append("quarto not found: compiled with pandoc, so code cells were not run.") }
            if engine != settings.pandocPdfEngine { notes.append("\(settings.pandocPdfEngine) not found: pandoc uses \(engine).") }
            return job(.steps([CompileStep("pandoc", [name, "-s", "-o", pdf.lastPathComponent, "--pdf-engine=\(engine)"])]), notes)
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
