import Foundation

/// One built-in snippet as shown in Settings → LaTeX Shortcuts.
public struct BuiltinSnippet: Equatable {
    /// Disable key: the plain trigger, or the raw regex source for regex
    /// snippets — matching what editor-core's `# chalk-disable:` expects.
    public let key: String
    /// Trigger text to display (regex sources shown verbatim).
    public let display: String
    public let description: String
    /// The snippet body as the editor would insert it: inline JS stripped,
    /// capture references rewritten to `#N`.
    public let replacement: String
    public let options: SnippetOptions
    /// The `# Title` banner this snippet sits under, which Settings groups by.
    /// Empty before the first banner.
    public let section: String

    public init(
        key: String,
        display: String,
        description: String,
        replacement: String,
        options: SnippetOptions,
        section: String = ""
    ) {
        self.key = key
        self.display = display
        self.description = description
        self.replacement = replacement
        self.options = options
        self.section = section
    }
}

/// Display-only scanner over an .hsnips file, feeding the Settings table.
/// Mirrors editor-core's parser; `HSnipsCatalogTests` checks it against the
/// bundled file. Blind spot: an `endsnippet` line inside a multi-line JS block
/// ends the body early.
public enum HSnipsCatalog {
    // Swift mirror of HEADER_RE in packages/editor-core/src/editor/hsnips-parser.ts.
    private static let headerRegex = try! NSRegularExpression(
        pattern: "^snippet ?(?:`([^`]+)`|(\\S+))?(?: \"([^\"]+)\")?(?: ([AMiwb]*))?"
    )
    // Mirror of CAPTURE_JS_RE: the one JS form we rewrite instead of drop.
    private static let captureJsRegex = try! NSRegularExpression(
        pattern: "^\\s*rv\\s*=\\s*m\\[(\\d+)\\]\\s*(\\.trim\\(\\))?\\s*;?\\s*$"
    )
    private static let inlineJsRegex = try! NSRegularExpression(pattern: "``([^`]*)``")

    public static func scan(_ content: String) -> [BuiltinSnippet] {
        var result: [BuiltinSnippet] = []
        var inGlobal = false
        var pendingContext: String?
        var section = ""
        // A banner is a `# Title` line after a `###` ruler; other `#` lines
        // (notes, `# chalk-disable:`) must not rename the section.
        var previousWasRuler = false
        var lines = content.components(separatedBy: .newlines)[...]

        while let line = lines.first {
            lines = lines.dropFirst()

            if inGlobal {
                if line.hasPrefix("endglobal") { inGlobal = false }
                continue
            }
            if line.hasPrefix("#") {
                let isRuler = line.allSatisfy { $0 == "#" } && line.count > 3
                if previousWasRuler && !isRuler {
                    section = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                previousWasRuler = isRuler
                continue
            }
            previousWasRuler = false
            if line.hasPrefix("global") { inGlobal = true; continue }
            if line.hasPrefix("context ") {
                pendingContext = String(line.dropFirst("context ".count))
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("snippet") else { continue }

            let range = NSRange(line.startIndex..., in: line)
            guard let m = headerRegex.firstMatch(in: line, range: range) else { continue }
            let group: (Int) -> String? = { index in
                guard let r = Range(m.range(at: index), in: line) else { return nil }
                return String(line[r])
            }

            let body = consumeBody(&lines)
            let regexSource = group(1)
            let plainTrigger = group(2)
            guard let trigger = regexSource ?? plainTrigger, !trigger.isEmpty else {
                pendingContext = nil
                continue
            }
            let flags = group(4) ?? ""
            let mode: SnippetOptions.Mode
            switch pendingContext {
            case "math(context)": mode = .math
            case "!math(context)": mode = .text
            default: mode = .any
            }
            result.append(BuiltinSnippet(
                key: trigger,
                display: trigger,
                description: group(3) ?? "",
                replacement: body,
                options: SnippetOptions(
                    mode: mode,
                    autoExpand: flags.contains("A"),
                    wholeWord: flags.contains("w"),
                    lineStart: flags.contains("b"),
                    isRegex: regexSource != nil
                ),
                section: section
            ))
            pendingContext = nil
        }
        return result
    }

    private static func consumeBody(_ lines: inout ArraySlice<String>) -> String {
        var body: [String] = []
        var inCode = false

        while let line = lines.first {
            lines = lines.dropFirst()

            if inCode {
                if line.contains("``") {
                    let after = line.components(separatedBy: "``").dropFirst()
                        .joined(separator: "``")
                    // The *rewritten* remainder decides, matching the parser:
                    // a bare closing marker adds no empty line.
                    let rewritten = rewriteInlineJs(after)
                    if !rewritten.isEmpty { body.append(rewritten) }
                    inCode = false
                }
                continue
            }
            if line.hasPrefix("endsnippet") { break }
            if !line.contains("``") { body.append(line); continue }

            let parts = line.components(separatedBy: "``")
            // parts.count - 1 is the number of `` markers.
            if (parts.count - 1) % 2 == 0 {
                body.append(rewriteInlineJs(line))
            } else {
                var result = ""
                var index = 0
                while index < parts.count - 1 {
                    result += parts[index]
                    index += 2
                }
                if !result.isEmpty { body.append(result) }
                inCode = true
            }
        }
        return body.joined(separator: "\n")
    }

    /// `rv = m[N]` (with or without `.trim()`) becomes `#N`; every other
    /// inline JS block is dropped.
    ///
    /// Unlike `parseBody`, the `.trim()` is dropped (it lives out of band in
    /// `HSnippet.trimmedCaptures`, and a fork's `#N` syntax has no trim
    /// marker), so a forked built-in no longer trims its capture.
    private static func rewriteInlineJs(_ line: String) -> String {
        var out = line
        let matches = inlineJsRegex
            .matches(in: line, range: NSRange(line.startIndex..., in: line))
            .reversed()
        for match in matches {
            guard let full = Range(match.range, in: line),
                  let inner = Range(match.range(at: 1), in: line) else { continue }
            let js = String(line[inner])
            let jsRange = NSRange(js.startIndex..., in: js)
            var replacement = ""
            if let capture = captureJsRegex.firstMatch(in: js, range: jsRange),
               let indexRange = Range(capture.range(at: 1), in: js) {
                replacement = "#\(js[indexRange])"
            }
            out.replaceSubrange(full, with: replacement)
        }
        return out
    }
}
