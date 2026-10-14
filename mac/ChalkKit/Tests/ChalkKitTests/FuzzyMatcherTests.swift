import XCTest
@testable import ChalkKit

final class FuzzyMatcherTests: XCTestCase {
    func testEmptyQueryScoresZero() {
        XCTAssertEqual(FuzzyMatcher.score(query: "", target: "anything.md"), 0)
        XCTAssertEqual(FuzzyMatcher.score(query: "   ", target: "anything.md"), 0)
    }

    func testNonSubsequenceReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score(query: "xyz", target: "abc.md"))
        XCTAssertNil(FuzzyMatcher.score(query: "zzz", target: "todo.md"))
    }

    func testMultiTermOrderIndependentAnd() {
        // Every term must match as a subsequence; order does not matter.
        XCTAssertNotNil(FuzzyMatcher.score(query: "todo personal", target: "todo-personal.md"))
        XCTAssertNotNil(FuzzyMatcher.score(query: "personal todo", target: "notes/todo-personal.md"))
        // A term that does not appear fails the whole match.
        XCTAssertNil(FuzzyMatcher.score(query: "todo missing", target: "todo-personal.md"))
    }

    func testWordBoundaryScoresHigherThanMidWord() throws {
        let boundary = try XCTUnwrap(FuzzyMatcher.score(query: "todo", target: "todo.md"))
        let midWord = try XCTUnwrap(FuzzyMatcher.score(query: "todo", target: "xtodo.md"))
        XCTAssertGreaterThan(boundary, midWord)
    }

    func testConsecutiveScoresHigherThanScattered() throws {
        let consecutive = try XCTUnwrap(FuzzyMatcher.score(query: "abc", target: "abc.md"))
        let scattered = try XCTUnwrap(FuzzyMatcher.score(query: "abc", target: "axbxc.md"))
        XCTAssertGreaterThan(consecutive, scattered)
    }

    func testFilterEmptyQueryReturnsFirstN() {
        let items = ["a", "b", "c", "d"]
        XCTAssertEqual(FuzzyMatcher.filter(query: "", items: items, key: { $0 }, limit: 2), ["a", "b"])
    }

    func testFilterRanksBestMatchFirst() {
        let files = ["notes/random.md", "todo.md", "archive/old-todo-list.md"]
        let ranked = FuzzyMatcher.filter(query: "todo", items: files, key: { $0 })
        XCTAssertEqual(ranked.first, "todo.md")
        XCTAssertFalse(ranked.contains("notes/random.md"), "non-matches are dropped")
    }

    func testFilterIsStableOnTies() {
        // Identical keys score equally; original order must be preserved.
        let items = ["dup-1", "dup-2", "dup-3"]
        let ranked = FuzzyMatcher.filter(query: "dup", items: items, key: { _ in "dup.md" })
        XCTAssertEqual(ranked, items)
    }
}
