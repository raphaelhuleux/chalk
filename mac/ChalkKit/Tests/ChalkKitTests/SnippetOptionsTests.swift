import XCTest
@testable import ChalkKit

final class SnippetOptionsTests: XCTestCase {
    func testDefaultsMatchTheOldTwoSwitchBehavior() {
        let options = SnippetOptions()
        XCTAssertEqual(options.mode, .math)
        XCTAssertTrue(options.autoExpand)
        XCTAssertFalse(options.wholeWord)
        XCTAssertFalse(options.lineStart)
        XCTAssertFalse(options.isRegex)
    }

    func testFlagString() {
        // `i` (match inside a word) is the default the composer has always
        // emitted; `w` replaces it rather than joining it.
        XCTAssertEqual(SnippetOptions().flagString, "Ai")
        XCTAssertEqual(SnippetOptions(autoExpand: false).flagString, "i")
        XCTAssertEqual(SnippetOptions(wholeWord: true).flagString, "Aw")
        XCTAssertEqual(SnippetOptions(lineStart: true).flagString, "Aib")
        XCTAssertEqual(
            SnippetOptions(autoExpand: false, wholeWord: true, lineStart: true).flagString,
            "wb"
        )
    }

    func testContextFilter() {
        XCTAssertEqual(SnippetOptions(mode: .math).contextFilter, "math(context)")
        XCTAssertEqual(SnippetOptions(mode: .text).contextFilter, "!math(context)")
        XCTAssertNil(SnippetOptions(mode: .any).contextFilter)
    }

    func testChipLabels() {
        XCTAssertEqual(SnippetOptions().chipLabels, ["Math", "Auto"])
        XCTAssertEqual(SnippetOptions(mode: .text).chipLabels, ["Text", "Auto"])
        XCTAssertEqual(SnippetOptions(mode: .any, autoExpand: false).chipLabels, [])
        XCTAssertEqual(
            SnippetOptions(mode: .math, wholeWord: true, lineStart: true).chipLabels,
            ["Math", "Auto", "Whole word", "Line start"]
        )
    }

    func testWholeWordChipIsHiddenOnARegexTrigger() {
        // editor-core's findMatch never reads `inword`/`wordboundary` on the
        // regex branch, so the chip would name a flag that does nothing.
        XCTAssertFalse(SnippetOptions(isRegex: true).wholeWordApplies)
        XCTAssertTrue(SnippetOptions().wholeWordApplies)
        XCTAssertEqual(
            SnippetOptions(mode: .math, wholeWord: true, lineStart: true, isRegex: true).chipLabels,
            ["Regex", "Math", "Auto", "Line start"]
        )
    }

    func testCodableRoundTrip() throws {
        let options = SnippetOptions(
            mode: .text, autoExpand: false, wholeWord: true, lineStart: true, isRegex: true)
        let data = try JSONEncoder().encode(options)
        XCTAssertEqual(try JSONDecoder().decode(SnippetOptions.self, from: data), options)
    }
}
