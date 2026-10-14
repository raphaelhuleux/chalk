import XCTest
@testable import ChalkKit

/// The payload a bug report attaches. Its whole reason to exist is that a
/// tester's report has to carry enough context to diagnose a bug while
/// carrying nothing that identifies them or their work — so most of what
/// these tests pin down is what the ring *cannot* hold.
final class DiagnosticsRingTests: XCTestCase {
    private func fixedClock(_ seconds: TimeInterval) -> () -> Date {
        { Date(timeIntervalSince1970: seconds) }
    }

    func testRecordingAnEventMakesItReadable() {
        let ring = DiagnosticsRing(capacity: 10, now: fixedClock(0))

        ring.record(.launch, a: 2)

        let events = ring.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .launch)
        XCTAssertEqual(events.first?.a, 2)
    }

    func testCapacityOverflowKeepsTheNewestEvents() {
        let ring = DiagnosticsRing(capacity: 3, now: fixedClock(0))

        for i in 0..<10 { ring.record(.launch, a: i) }

        XCTAssertEqual(ring.events().map(\.a), [7, 8, 9])
    }

    func testCapacityOverflowReportsHowManyWereDropped() {
        let ring = DiagnosticsRing(capacity: 3, now: fixedClock(0))

        for i in 0..<10 { ring.record(.launch, a: i) }

        XCTAssertEqual(ring.droppedCount(), 7)
    }

    // MARK: - Privacy guarantees

    /// The load-bearing test. Cocoa errors carry the file path in
    /// `NSFilePathErrorKey` and the file *name* inside the localized
    /// description ("The file "secret-chapter.md" couldn't be opened"), so
    /// capturing an Error naively leaks both. DiagError must read domain and
    /// code and nothing else.
    func testErrorCapturesOnlyDomainAndCodeNotThePathOrDescription() {
        let leaky = NSError(domain: NSCocoaErrorDomain, code: 260, userInfo: [
            NSFilePathErrorKey: "/Users/someone/Thesis/secret-chapter.md",
            NSLocalizedDescriptionKey: "The file \u{201C}secret-chapter.md\u{201D} couldn\u{2019}t be opened.",
        ])
        let ring = DiagnosticsRing(capacity: 10, now: fixedClock(0))

        ring.record(.recoveryPurged, error: DiagError(leaky))

        let captured = ring.events().first?.error
        XCTAssertEqual(captured, DiagError(domain: .cocoa, code: 260))

        let rendered = ring.render()
        for secret in ["secret", "Thesis", "someone", "chapter", "couldn"] {
            XCTAssertFalse(rendered.contains(secret),
                           "rendered diagnostics leaked \(secret): \(rendered)")
        }
    }

    /// A structural guard, not a behavioural one: it fails if someone later
    /// adds a String/URL/Data field to the event type. The privacy property
    /// is meant to hold by construction, so it needs a test that survives
    /// changes nobody thought to check.
    func testEventDeclaresNoStringOrURLOrDataFields() {
        let ring = DiagnosticsRing(capacity: 10, now: fixedClock(0))
        ring.record(.recoveryPurged, a: 1, b: 2, c: 3, ms: 4,
                    error: DiagError(domain: .posix, code: 2))
        let event = try! XCTUnwrap(ring.events().first)

        var offenders: [String] = []
        func inspect(_ mirror: Mirror, path: String, depth: Int) {
            for child in mirror.children {
                let label = child.label ?? "?"
                let type = String(describing: type(of: child.value))
                if ["String", "Optional<String>", "URL", "Optional<URL>",
                    "Data", "Optional<Data>"].contains(type) {
                    offenders.append("\(path).\(label): \(type)")
                }
                if depth < 2 { inspect(Mirror(reflecting: child.value),
                                       path: "\(path).\(label)", depth: depth + 1) }
            }
        }
        inspect(Mirror(reflecting: event), path: "DiagEvent", depth: 0)

        XCTAssertEqual(offenders, [], "a free-text field can carry user data")
    }

    // MARK: - Coalescing

    /// A timer- or scroll-driven event repeating in a tight loop would
    /// otherwise evict the whole ring and take the interesting history with
    /// it. Adjacent identical observations collapse into a count instead.
    func testAdjacentIdenticalEventsCoalesceIntoOneRow() {
        let ring = DiagnosticsRing(capacity: 10, now: fixedClock(0))

        for _ in 0..<5 { ring.record(.launch, a: 1) }

        XCTAssertEqual(ring.events().count, 1)
        XCTAssertEqual(ring.events().first?.repeats, 5)
    }

    /// Only *adjacent* ones. A repeat that happened later, after something
    /// else, is a different occurrence and the gap between them is the
    /// diagnostically interesting part.
    func testNonAdjacentIdenticalEventsStaySeparate() {
        let ring = DiagnosticsRing(capacity: 10, now: fixedClock(0))

        ring.record(.launch, a: 1)
        ring.record(.recoveryPurged)
        ring.record(.launch, a: 1)

        XCTAssertEqual(ring.events().map(\.kind), [.launch, .recoveryPurged, .launch])
        XCTAssertEqual(ring.events().map(\.repeats), [1, 1, 1])
    }

    /// Coalescing must not defeat the capacity bound's purpose of keeping the
    /// newest history: a run of repeats occupies one slot, not N.
    func testCoalescingDoesNotConsumeCapacity() {
        let ring = DiagnosticsRing(capacity: 3, now: fixedClock(0))

        for _ in 0..<100 { ring.record(.launch, a: 1) }

        XCTAssertEqual(ring.events().count, 1)
        XCTAssertEqual(ring.droppedCount(), 0)
    }

    // MARK: - Rendering

    /// Elapsed seconds, never wall-clock. A reader needs the gaps between
    /// events; an absolute stamp would also disclose the tester's timezone and
    /// working hours for no diagnostic gain.
    func testRenderShowsElapsedSecondsNotWallClock() {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let ring = DiagnosticsRing(capacity: 10, now: { clock })

        ring.record(.launch)
        clock = clock.addingTimeInterval(1.5)
        ring.record(.recoveryPurged)

        let rendered = ring.render()
        XCTAssertTrue(rendered.contains("+0.000"), rendered)
        XCTAssertTrue(rendered.contains("+1.500"), rendered)
        XCTAssertFalse(rendered.contains("1700000000"), rendered)
        XCTAssertFalse(rendered.contains("2023"), rendered)
    }

    func testRenderIsDeterministic() {
        let ring = DiagnosticsRing(capacity: 10, now: fixedClock(0))
        ring.record(.launch, a: 1)
        ring.record(.recoveryPurged, ms: 42)

        XCTAssertEqual(ring.render(), ring.render())
    }

    func testRenderLimitKeepsTheNewestEvents() {
        let ring = DiagnosticsRing(capacity: 100, now: fixedClock(0))
        for i in 0..<10 { ring.record(.launch, a: i) }

        let rendered = ring.render(limit: 2)

        XCTAssertTrue(rendered.contains("a=9"), rendered)
        XCTAssertTrue(rendered.contains("a=8"), rendered)
        XCTAssertFalse(rendered.contains("a=7"), rendered)
    }

    func testRenderHeaderReportsEventsHiddenByTheLimit() {
        let ring = DiagnosticsRing(capacity: 100, now: fixedClock(0))
        for i in 0..<10 { ring.record(.launch, a: i) }

        XCTAssertTrue(ring.render(limit: 2).contains("8 earlier dropped"),
                      ring.render(limit: 2))
    }

    /// The output alphabet is closed: kind raw values, digits, and a fixed set
    /// of separators. Drive every case with adversarial integers and assert
    /// nothing else can appear. This is what stops a future kind whose raw
    /// value contains prose, or a formatter that echoes something unexpected.
    func testRenderOfEveryKindStaysInAClosedAlphabet() {
        let ring = DiagnosticsRing(capacity: DiagKind.allCases.count * 4,
                                   now: fixedClock(0))
        for (i, kind) in DiagKind.allCases.enumerated() {
            ring.record(kind, a: Int.min, b: Int.max, c: -i, ms: i,
                        error: DiagError(domain: .cocoa, code: Int.min))
        }

        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 +-.=/,x\n")
        let rendered = ring.render()
        let offending = rendered.unicodeScalars.filter { !allowed.contains($0) }

        XCTAssertTrue(offending.isEmpty,
                      "unexpected characters \(Set(offending.map(String.init))) in:\n\(rendered)")
    }

    func testEveryKindRawValueIsLowercaseAndHyphenated() {
        for kind in DiagKind.allCases {
            XCTAssertEqual(kind.rawValue, kind.rawValue.lowercased(), "\(kind)")
            XCTAssertFalse(kind.rawValue.contains(" "), "\(kind)")
            XCTAssertFalse(kind.rawValue.isEmpty, "\(kind)")
        }
    }
}

/// The safe replacement for `error.localizedDescription` in a log line marked
/// public. Two call sites redacted the file name and then interpolated the
/// error's prose as public, which hands it straight back: a failed write of
/// `secret-thesis-chapter.md` renders as `You don't have permission to save the
/// file "secret-thesis-chapter.md" in the folder "..."`.
final class DiagErrorDescriptionTests: XCTestCase {
    private func fileError(path: String) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [
            NSFilePathErrorKey: path,
            NSLocalizedDescriptionKey:
                "You don\u{2019}t have permission to save the file "
                + "\u{201C}\((path as NSString).lastPathComponent)\u{201D}.",
        ])
    }

    func testDescriptionIsDomainAndCodeOnly() {
        let error = fileError(path: "/Users/x/Thesis/secret-chapter.md")
        XCTAssertEqual(String(describing: DiagError(error)), "cocoa/513")
    }

    func testDescriptionCarriesNoFragmentOfThePathOrTheProse() {
        let error = fileError(path: "/Users/someone/Thesis/secret-chapter.md")
        let rendered = String(describing: DiagError(error))
        for leak in ["secret", "chapter", "Thesis", "someone", "permission", ".md", "/Users"] {
            XCTAssertFalse(rendered.contains(leak),
                           "DiagError's description leaked '\(leak)': \(rendered)")
        }
    }

    func testUnknownDomainsStillRenderWithoutTheirOwnText() {
        let error = NSError(domain: "com.acme.SecretVault", code: 7,
                            userInfo: [NSLocalizedDescriptionKey: "vault /Users/x/private"])
        XCTAssertEqual(String(describing: DiagError(error)), "other/7")
    }
}
