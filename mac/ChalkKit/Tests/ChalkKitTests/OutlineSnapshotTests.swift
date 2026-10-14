import XCTest
@testable import ChalkKit

/// Decoding parity with the TS `OutlineItem`/snapshot JSON that
/// `window.__chalkEditor.getOutlineSnapshot()` produces (see
/// packages/editor-core/src/editor/outline.ts). Fixtures are written to the
/// exact byte-shape of the wire: optional fields are ABSENT, never null.
final class OutlineSnapshotTests: XCTestCase {
    func testDecodesFullSnapshotFromWireShape() throws {
        let json = """
        {"items":[\
        {"kind":"heading","level":1,"title":"Intro","line":1},\
        {"kind":"callout","level":0,"title":"Pythagoras","line":3,"calloutType":"theorem","number":1},\
        {"kind":"figure","level":0,"title":"Residual geometry","line":7,"number":1}\
        ],"cursorLine":14}
        """
        let snap = try JSONDecoder().decode(OutlineSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(snap.cursorLine, 14)
        XCTAssertEqual(snap.items.count, 3)
        XCTAssertEqual(
            snap.items[0],
            OutlineItem(kind: .heading, level: 1, title: "Intro", line: 1,
                        calloutType: nil, number: nil))
        XCTAssertEqual(
            snap.items[1],
            OutlineItem(kind: .callout, level: 0, title: "Pythagoras", line: 3,
                        calloutType: "theorem", number: 1))
        XCTAssertEqual(
            snap.items[2],
            OutlineItem(kind: .figure, level: 0, title: "Residual geometry", line: 7,
                        calloutType: nil, number: 1))
    }

    /// editor-core sends `selectionWords: null` (not absent) when nothing is
    /// selected, and no `stats` at all before `init`.
    func testDecodesStatsInBothWireShapes() throws {
        let idle = #"{"items":[],"cursorLine":1,"stats":{"words":1234,"characters":6789,"selectionWords":null}}"#
        XCTAssertEqual(
            try JSONDecoder().decode(OutlineSnapshot.self, from: Data(idle.utf8)).stats,
            DocumentStats(words: 1234, characters: 6789, selectionWords: nil))
        let selecting = #"{"items":[],"cursorLine":1,"stats":{"words":10,"characters":40,"selectionWords":3}}"#
        XCTAssertEqual(
            try JSONDecoder().decode(OutlineSnapshot.self, from: Data(selecting.utf8)).stats?.selectionWords,
            3)
        let preInit = #"{"items":[],"cursorLine":1}"#
        XCTAssertNil(try JSONDecoder().decode(OutlineSnapshot.self, from: Data(preInit.utf8)).stats)
    }

    /// A malformed `stats` costs the footer, never the outline.
    func testMalformedStatsKeepTheItems() throws {
        let json = #"{"items":[{"kind":"heading","level":1,"title":"A","line":1}],"cursorLine":1,"stats":{"words":"many"}}"#
        let snap = try JSONDecoder().decode(OutlineSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snap.stats)
        XCTAssertEqual(snap.items.count, 1)
    }

    func testAbsentOptionalsDecodeAsNil() throws {
        let json = #"{"items":[{"kind":"heading","level":2,"title":"A","line":5}],"cursorLine":1}"#
        let snap = try JSONDecoder().decode(OutlineSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snap.items[0].calloutType)
        XCTAssertNil(snap.items[0].number)
    }

    /// Forward compatibility: a newer editor bundle may emit outline kinds an
    /// older app doesn't know. One unknown item must drop, not blank the whole
    /// palette.
    func testUnknownKindItemsAreDroppedNotFatal() throws {
        let json = """
        {"items":[\
        {"kind":"heading","level":1,"title":"Intro","line":1},\
        {"kind":"mystery","level":0,"title":"x","line":3},\
        {"kind":"figure","level":0,"title":"conv","line":7,"number":1}\
        ],"cursorLine":5}
        """
        let snap = try JSONDecoder().decode(OutlineSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.cursorLine, 5)
        XCTAssertEqual(snap.items.map(\.line), [1, 7], "known-kind items survive in order")
        XCTAssertEqual(snap.items.map(\.kind), [.heading, .figure])
    }

    func testAllUnknownKindsDecodeToEmptyOutline() throws {
        let json = #"{"items":[{"kind":"mystery","level":0,"title":"x","line":1}],"cursorLine":1}"#
        let snap = try JSONDecoder().decode(OutlineSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.items, [])
        XCTAssertEqual(snap.cursorLine, 1)
    }

    /// Leniency is scoped to unknown `kind` values only: a KNOWN kind with a
    /// malformed body (or a missing kind) is wire drift and must stay loud.
    func testMalformedKnownKindItemStillFailsToDecode() {
        let missingLine = #"{"items":[{"kind":"heading","level":1,"title":"A"}],"cursorLine":1}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(OutlineSnapshot.self, from: Data(missingLine.utf8)))
        let missingKind = #"{"items":[{"level":1,"title":"A","line":2}],"cursorLine":1}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(OutlineSnapshot.self, from: Data(missingKind.utf8)))
    }

    func testBadgeTextPerKind() {
        let theorem = OutlineItem(kind: .callout, level: 0, title: "Pythagoras", line: 3,
                                  calloutType: "theorem", number: 3)
        let figure = OutlineItem(kind: .figure, level: 0, title: "conv", line: 7,
                                 calloutType: nil, number: 2)
        let heading = OutlineItem(kind: .heading, level: 1, title: "Intro", line: 1,
                                  calloutType: nil, number: nil)
        XCTAssertEqual(theorem.badge, "Theorem 3")
        XCTAssertEqual(figure.badge, "Fig. 2")
        XCTAssertNil(heading.badge)
    }
}

/// Beamer frames ride the same wire as every other outline item. The kind must
/// be known here or the lenient decoder silently DROPS every slide — a deck's
/// outline would come back empty rather than loudly wrong.
extension OutlineSnapshotTests {
    func testDecodesBeamerFrameItems() throws {
        let json = """
        {"items":[\
        {"kind":"frame","level":0,"title":"Bayesian updating","line":12,"number":3}\
        ],"cursorLine":12}
        """
        let snap = try JSONDecoder().decode(OutlineSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.items.count, 1, "frame items must not be dropped as unknown")
        XCTAssertEqual(
            snap.items[0],
            OutlineItem(kind: .frame, level: 0, title: "Bayesian updating", line: 12,
                        calloutType: nil, number: 3))
    }

    func testFrameBadgeReadsAsASlideNumber() {
        let framed = OutlineItem(kind: .frame, level: 0, title: "Roadmap", line: 4,
                                 calloutType: nil, number: 2)
        XCTAssertEqual(framed.badge, "Slide 2")

        let unnumbered = OutlineItem(kind: .frame, level: 0, title: "Roadmap", line: 4,
                                     calloutType: nil, number: nil)
        XCTAssertEqual(unnumbered.badge, "Slide")
    }
}
