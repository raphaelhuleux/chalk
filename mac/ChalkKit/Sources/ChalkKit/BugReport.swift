import Foundation

public enum BugReportKind: String, Sendable, CaseIterable {
    case bug, feedback

    var subjectPhrase: String {
        switch self {
        case .bug: return "bug report"
        case .feedback: return "feedback"
        }
    }
}

/// Which build, on what. Nothing here comes from the user's disk, so the
/// block ships untruncated.
public struct BugReportEnvironment: Equatable, Sendable {
    public let appVersion: String
    public let build: String
    public let commit: String
    public let systemVersion: String
    public let model: String
    public let locale: String

    public init(appVersion: String, build: String, commit: String,
                systemVersion: String, model: String, locale: String) {
        self.appVersion = appVersion
        self.build = build
        self.commit = commit
        self.systemVersion = systemVersion
        self.model = model
        self.locale = locale
    }
}

/// Composes the exact bytes a user is about to file as a GitHub issue. One
/// pure function, so the in-app preview and the payload are the same string.
public enum BugReport {
    /// The diagnostics block is last and fenced so it can be deleted in one
    /// gesture before submitting.
    public static let diagnosticsFence =
        "--- diagnostics: counts and timings only, no file names, paths or text ---"
    private static let environmentFence = "--- build ---"

    public static func subject(kind: BugReportKind,
                               environment: BugReportEnvironment) -> String {
        "Chalk \(kind.subjectPhrase) - \(environment.appVersion) (\(environment.build))"
    }

    /// Order is load-bearing: notes, build identity, then the ring, so deleting
    /// the ring keeps the build identity.
    public static func body(kind: BugReportKind,
                            notes: String,
                            environment: BugReportEnvironment,
                            diagnostics: String?) -> String {
        var parts = [notes.trimmingCharacters(in: .whitespacesAndNewlines)]

        parts.append([
            environmentFence,
            "Chalk \(environment.appVersion) (build \(environment.build), \(environment.commit))",
            environment.systemVersion,
            "\(environment.model), \(environment.locale)",
        ].joined(separator: "\n"))

        if let diagnostics, !diagnostics.isEmpty {
            parts.append(diagnosticsFence + "\n" + diagnostics)
        }
        return parts.joined(separator: "\n\n")
    }

    /// A GitHub new-issue URL with the title and body prefilled as query
    /// items, everything percent-encoded.
    ///
    /// `.urlQueryAllowed` alone is wrong: it permits `&`, which truncates the
    /// body, and `+`, which is read as a space.
    public static func newIssueURL(base: String, title: String, body: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+?=#/")
        guard let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: allowed),
              let encodedBody = body.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: "\(base)?title=\(encodedTitle)&body=\(encodedBody)")
    }

    /// Trim the ring, and only the ring: an over-long URL is refused whole,
    /// and the notes and build identity must survive. The trim always says it
    /// happened, so a shortened report never reads as complete.
    public static func truncateForURL(_ body: String, limit: Int) -> String {
        guard body.count > limit else { return body }
        guard let fenceRange = body.range(of: diagnosticsFence) else {
            // Nothing trimmable: hand back the whole thing and let the
            // browser decide.
            return body
        }

        let head = String(body[body.startIndex..<fenceRange.lowerBound])
        let note = "\n\(diagnosticsFence)\n[trimmed to fit the issue URL]\n"
        let room = limit - head.count - note.count
        guard room > 0 else { return head + "\n[trimmed: diagnostics did not fit]" }

        let ring = String(body[fenceRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the tail: the events nearest what the user is describing.
        return head + note + String(ring.suffix(room))
    }
}
