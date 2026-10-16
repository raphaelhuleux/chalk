import Foundation

/// An error or warning from a compile, located when the output says where.
public struct CompileIssue: Equatable, Sendable {
    public enum Severity: String, Sendable { case error, warning }

    public var severity: Severity
    /// As the tool printed it, `./` stripped; relative to the working directory.
    public var file: String?
    public var line: Int?
    public var message: String

    public init(severity: Severity, file: String?, line: Int?, message: String) {
        self.severity = severity
        self.file = file
        self.line = line
        self.message = message
    }
}

/// Issues from latexmk / pdflatex (`-file-line-error`), tectonic and pandoc output.
public enum CompileLog {
    private static let fileLineError = LatexRoot.regex(#"^(.+?\.(?:tex|sty|cls|ltx|bib|dtx)):(\d+): (.+)$"#)
    private static let tectonic = LatexRoot.regex(#"^(error|warning): (.+?\.(?:tex|sty|cls|ltx|bib)):(\d+): (.+)$"#)
    private static let latexWarning = LatexRoot.regex(#"^(?:LaTeX|Package \w+) Warning: (.+?)(?: on input line (\d+))?\.?$"#)
    private static let bareError = LatexRoot.regex(#"^! (.+)$"#)
    private static let lineMarker = LatexRoot.regex(#"^l\.(\d+)"#)

    private static func groups(_ re: NSRegularExpression, _ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    private static func cleanFile(_ f: String) -> String {
        f.hasPrefix("./") ? String(f.dropFirst(2)) : f
    }

    /// Errors first, then warnings, each in output order, without the
    /// duplicates latexmk prints when it repeats a pass.
    public static func issues(in output: String) -> [CompileIssue] {
        let lines = output.components(separatedBy: .newlines)
        var errors: [CompileIssue] = []
        var warnings: [CompileIssue] = []
        var seen = Set<String>()
        func add(_ issue: CompileIssue) {
            let key = "\(issue.severity)|\(issue.file ?? "")|\(issue.line ?? 0)|\(issue.message)"
            guard seen.insert(key).inserted else { return }
            if issue.severity == .error { errors.append(issue) } else { warnings.append(issue) }
        }
        for (i, line) in lines.enumerated() {
            if let g = groups(tectonic, line), let file = g[2], let ln = g[3], let msg = g[4] {
                add(CompileIssue(severity: g[1] == "error" ? .error : .warning, file: cleanFile(file), line: Int(ln), message: msg))
            } else if let g = groups(fileLineError, line), let file = g[1], let ln = g[2], let msg = g[3] {
                add(CompileIssue(severity: .error, file: cleanFile(file), line: Int(ln), message: msg))
            } else if let g = groups(bareError, line), let msg = g[1] {
                // Without -file-line-error TeX names the line a few lines later as `l.42`.
                let lineNo = lines[(i + 1)..<min(lines.count, i + 8)].lazy.compactMap { groups(lineMarker, $0)?[1] ?? nil }.first
                add(CompileIssue(severity: .error, file: nil, line: lineNo.flatMap { Int($0) }, message: msg))
            } else if let g = groups(latexWarning, line), let msg = g[1] {
                add(CompileIssue(severity: .warning, file: nil, line: g[2].flatMap { Int($0) }, message: msg))
            }
        }
        return errors + warnings
    }
}

/// SyncTeX through the `synctex` command-line tool that ships with TeX Live.
/// Coordinates are PDF points from the page's top-left corner.
public enum SyncTeX {
    public struct PDFLocation: Equatable, Sendable {
        public var page: Int
        /// Left edge and baseline of the box, then its size.
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
    }

    public struct SourceLocation: Equatable, Sendable {
        public var input: String
        public var line: Int
    }

    /// `synctex view`: source line to PDF box.
    public static func viewArguments(line: Int, column: Int = 0, input: String, pdf: String) -> [String] {
        ["view", "-i", "\(line):\(column):\(input)", "-o", pdf]
    }

    /// `synctex edit`: PDF point to source line.
    public static func editArguments(page: Int, x: Double, y: Double, pdf: String) -> [String] {
        ["edit", "-o", "\(page):\(x):\(y):\(pdf)"]
    }

    /// `Key:value` lines of the first result record.
    private static func firstRecord(_ output: String) -> [String: String] {
        var record: [String: String] = [:]
        var inResult = false
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("SyncTeX result begin") { inResult = true; continue }
            if line.hasPrefix("SyncTeX result end") { break }
            guard inResult, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            // A second record repeats `Output:`; keep the first.
            if key == "Output", record["Output"] != nil { break }
            record[key] = String(line[line.index(after: colon)...])
        }
        return record
    }

    public static func parseView(_ output: String) -> PDFLocation? {
        let r = firstRecord(output)
        guard let page = r["Page"].flatMap(Int.init),
              let h = r["h"].flatMap(Double.init), let v = r["v"].flatMap(Double.init) else { return nil }
        return PDFLocation(
            page: page, x: h, y: v,
            width: r["W"].flatMap(Double.init) ?? 0,
            height: r["H"].flatMap(Double.init) ?? 0
        )
    }

    public static func parseEdit(_ output: String) -> SourceLocation? {
        let r = firstRecord(output)
        guard let input = r["Input"], let line = r["Line"].flatMap(Int.init), line > 0 else { return nil }
        return SourceLocation(input: URL(fileURLWithPath: input).standardizedFileURL.path, line: line)
    }
}
