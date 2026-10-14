import Foundation
import os
import ChalkKit

/// The app's one way into the diagnostics ring.
///
/// `record` accepts no free text at any arity, so the payload is safe to file
/// publicly without review; `scripts/check-diagnostics-purity.mjs` fails the build if
/// the signature or a call site erodes that.
///
/// Events mirror to the unified log as `privacy: .public`, which is safe only
/// because nothing that could need redacting can be in an event. `log stream`
/// and the in-app report then show the same sequence.
enum Diagnostics {
    /// Headroom, not history: a handful of events per launch, and the bound
    /// keeps a long session's report inside an issue URL after
    /// `BugReport.truncateForURL`.
    private static let ring = DiagnosticsRing(capacity: 300)
    private static let log = Logger(subsystem: "com.huleux.chalk", category: "diag")

    /// The only ingress, mirroring `DiagnosticsRing.record` exactly: a per-kind
    /// wrapper would be one more place for a String parameter to appear.
    static func record(_ kind: DiagKind, a: Int? = nil, b: Int? = nil,
                       c: Int? = nil, ms: Int? = nil) {
        ring.record(kind, a: a, b: b, c: c, ms: ms)

        var line = kind.rawValue
        for (label, value) in [("a", a), ("b", b), ("c", c), ("ms", ms)] {
            if let value { line += " \(label)=\(value)" }
        }
        log.info("\(line, privacy: .public)")
    }

    /// The block a bug report carries, oldest event first.
    static func render(limit: Int = 200) -> String { ring.render(limit: limit) }
}
