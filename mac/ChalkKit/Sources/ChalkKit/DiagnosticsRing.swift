import Foundation

/// Every event a bug report can carry. Closed so a call site cannot widen the
/// report's vocabulary. Add a case together with its first
/// `Diagnostics.record`.
public enum DiagKind: String, CaseIterable, Sendable {
    /// `a` carries the previous session's exit verdict.
    case launch

    // The crash net.
    case recoveryResidueFound = "recovery-residue-found"
    case recoveryPurged = "recovery-purged"
}

public enum DiagErrorDomain: String, Sendable {
    case cocoa, posix, osStatus = "osstatus", webKit = "webkit"
    case urlError = "urlerror", chalk, other
}

/// An error reduced to the two facts that are safe to transmit. `userInfo`
/// (file paths, URLs) and `localizedDescription` (embeds file names) both
/// leak, so only domain and code are read.
public struct DiagError: Equatable, Sendable {
    public let domain: DiagErrorDomain
    public let code: Int

    public init(_ error: Error) {
        let ns = error as NSError
        self.domain = DiagErrorDomain(nsDomain: ns.domain)
        self.code = ns.code
    }

    public init(domain: DiagErrorDomain, code: Int) {
        self.domain = domain
        self.code = code
    }
}

extension DiagError: CustomStringConvertible {
    /// `"cocoa/513"`: safe in a `privacy: .public` log line because it is a
    /// closed enum and an integer. Use it instead of
    /// `error.localizedDescription`, which embeds paths;
    /// `scripts/check-diagnostics-purity.mjs` fails the build on that shape.
    public var description: String { "\(domain.rawValue)/\(code)" }
}

private extension DiagErrorDomain {
    /// String-matched rather than symbol-matched because ChalkKit is pure
    /// Foundation: it cannot import WebKit to reach `WKErrorDomain`.
    init(nsDomain: String) {
        switch nsDomain {
        case NSCocoaErrorDomain: self = .cocoa
        case NSPOSIXErrorDomain: self = .posix
        case NSOSStatusErrorDomain: self = .osStatus
        case NSURLErrorDomain: self = .urlError
        case "WKErrorDomain": self = .webKit
        case let d where d.hasPrefix("com.huleux.chalk"): self = .chalk
        default: self = .other
        }
    }
}

/// One diagnostic observation. Every field is an enum, a number, or a date;
/// `DiagnosticsRingTests.testEventDeclaresNoStringOrURLOrDataFields` fails if
/// a `String`, `URL`, or `Data` property is added.
public struct DiagEvent: Equatable, Sendable {
    public let kind: DiagKind
    public let at: Date
    public let a: Int?
    public let b: Int?
    public let c: Int?
    public let ms: Int?
    public let error: DiagError?
    public internal(set) var repeats: Int = 1
}

/// A bounded, in-memory log of what the app was doing, sized to fit in a
/// bug report and safe to send without review: `record` accepts no free text, so a
/// file name cannot be logged.
public final class DiagnosticsRing: @unchecked Sendable {
    private let capacity: Int
    private let now: () -> Date
    private let startedAt: Date
    private let lock = NSLock()
    private var stored: [DiagEvent] = []
    private var dropped = 0

    public init(capacity: Int = 200, now: @escaping () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.now = now
        self.startedAt = now()
    }

    /// The only ingress. No `String` parameter exists at any arity.
    public func record(_ kind: DiagKind, a: Int? = nil, b: Int? = nil,
                       c: Int? = nil, ms: Int? = nil, error: DiagError? = nil) {
        let event = DiagEvent(kind: kind, at: now(), a: a, b: b, c: c, ms: ms,
                              error: error)
        lock.lock()
        defer { lock.unlock() }

        // Coalesce an immediate repeat, or a tight-loop event would evict
        // the whole ring.
        if var last = stored.last, last.isSameObservation(as: event) {
            last.repeats += 1
            stored[stored.count - 1] = last
            return
        }

        stored.append(event)
        if stored.count > capacity {
            let excess = stored.count - capacity
            dropped += excess
            stored.removeFirst(excess)
        }
    }

    public func events() -> [DiagEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Events evicted by capacity. Rendered in the header so a reader knows
    /// the log is a tail, not the whole session.
    public func droppedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    /// Deterministic plain text for the report body. Times are elapsed
    /// seconds since the ring started, never wall-clock, so no timezone or
    /// time of day leaks.
    public func render(limit: Int? = nil) -> String {
        let all = events()
        let shown = limit.map { Array(all.suffix(max(0, $0))) } ?? all
        let omitted = all.count - shown.count + droppedCount()

        var header = "CHALK DIAGNOSTICS  \(shown.count) event"
            + (shown.count == 1 ? "" : "s")
        if omitted > 0 { header += ", \(omitted) earlier dropped" }

        return ([header] + shown.map(row)).joined(separator: "\n")
    }

    private func row(_ event: DiagEvent) -> String {
        let elapsed = event.at.timeIntervalSince(startedAt)
        var line = String(format: "  %+8.3f  %-28@", elapsed,
                          event.kind.rawValue as NSString)
        var fields: [String] = []
        if let a = event.a { fields.append("a=\(a)") }
        if let b = event.b { fields.append("b=\(b)") }
        if let c = event.c { fields.append("c=\(c)") }
        if let ms = event.ms { fields.append("\(ms)ms") }
        if let error = event.error {
            fields.append("err=\(error.description)")
        }
        if event.repeats > 1 { fields.append("x\(event.repeats)") }
        line += fields.joined(separator: " ")
        return line
    }
}

private extension DiagEvent {
    /// Equality for coalescing: ignores timestamp and repeat count.
    func isSameObservation(as other: DiagEvent) -> Bool {
        kind == other.kind && a == other.a && b == other.b && c == other.c
            && ms == other.ms && error == other.error
    }
}
