import XCTest
@testable import ChalkKit

final class TextMergeTests: XCTestCase {
    private let base = "# Title\n\nalpha\nbeta\ngamma\ndelta\nepsilon\n"

    func testOneSidedChangesPassThrough() {
        XCTAssertEqual(TextMerge.threeWay(base: base, mine: base, theirs: "x\n"), "x\n")
        XCTAssertEqual(TextMerge.threeWay(base: base, mine: "x\n", theirs: base), "x\n")
        XCTAssertEqual(TextMerge.threeWay(base: base, mine: "x\n", theirs: "x\n"), "x\n")
    }

    func testDisjointEditsBothLand() {
        let mine = base.replacingOccurrences(of: "alpha", with: "ALPHA")
        let theirs = base.replacingOccurrences(of: "epsilon", with: "epsilon\nzeta")
        XCTAssertEqual(TextMerge.threeWay(base: base, mine: mine, theirs: theirs),
                       "# Title\n\nALPHA\nbeta\ngamma\ndelta\nepsilon\nzeta\n")
    }

    func testDisjointDeletionAndInsertion() {
        let mine = base.replacingOccurrences(of: "beta\n", with: "")
        let theirs = "intro\n" + base
        XCTAssertEqual(TextMerge.threeWay(base: base, mine: mine, theirs: theirs),
                       "intro\n# Title\n\nalpha\ngamma\ndelta\nepsilon\n")
    }

    func testSameLineEditedBothWaysIsAConflict() {
        let mine = base.replacingOccurrences(of: "gamma", with: "GAMMA")
        let theirs = base.replacingOccurrences(of: "gamma", with: "gamma!")
        XCTAssertNil(TextMerge.threeWay(base: base, mine: mine, theirs: theirs))
    }

    /// Neighbouring lines are refused too: with no untouched line between them, the order of the
    /// two changes is a guess.
    func testAdjacentLinesAreAConflict() {
        let mine = base.replacingOccurrences(of: "beta", with: "BETA")
        let theirs = base.replacingOccurrences(of: "gamma", with: "GAMMA")
        XCTAssertNil(TextMerge.threeWay(base: base, mine: mine, theirs: theirs))
    }

    func testIdenticalChangeOnBothSidesMergesOnce() {
        let both = base.replacingOccurrences(of: "beta", with: "BETA")
        let mine = both.replacingOccurrences(of: "epsilon", with: "EPSILON")
        XCTAssertEqual(TextMerge.threeWay(base: base, mine: mine, theirs: both), mine)
    }

    func testTrailingNewlineAndCRLFSurvive() {
        let crlf = "a\r\nb\r\nc\r\nd\r\ne"
        let mine = crlf.replacingOccurrences(of: "a\r", with: "A\r")
        let theirs = crlf.replacingOccurrences(of: "e", with: "E")
        XCTAssertEqual(TextMerge.threeWay(base: crlf, mine: mine, theirs: theirs), "A\r\nb\r\nc\r\nd\r\nE")
    }

    func testRepeatedLinesMergeByPosition() {
        let rep = "x\nx\nx\nx\nx\n"
        let mine = "y\nx\nx\nx\nx\n"
        let theirs = "x\nx\nx\nx\nz\n"
        XCTAssertEqual(TextMerge.threeWay(base: rep, mine: mine, theirs: theirs), "y\nx\nx\nx\nz\n")
    }
}
