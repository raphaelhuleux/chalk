import XCTest
@testable import ChalkKit

final class SnippetComposerTests: XCTestCase {
    private let base = "snippet ;; \"Inline math\" iA\n\\$$0\\$\nendsnippet\n"

    func testNoUserContentReturnsBaseUnchanged() {
        XCTAssertEqual(
            SnippetComposer.compose(base: base, user: [], disabledBuiltins: []),
            base
        )
        let disabledOnly = UserSnippet(trigger: ";a", replacement: "x", enabled: false)
        XCTAssertEqual(
            SnippetComposer.compose(base: base, user: [disabledOnly], disabledBuiltins: []),
            base
        )
    }

    func testEmitsPriorityAndContextBeforeEverySnippet() {
        let user = [
            UserSnippet(trigger: ";a", replacement: "\\alpha", options: SnippetOptions(mode: .math)),
            UserSnippet(trigger: ";b", replacement: "\\beta", options: SnippetOptions(mode: .math)),
        ]
        let out = SnippetComposer.compose(base: base, user: user, disabledBuiltins: [])
        // The parser resets priority/context after each snippet, so both
        // lines must appear once per user snippet.
        XCTAssertEqual(occurrences(of: "priority 10\n", in: out), 2)
        XCTAssertEqual(occurrences(of: "context math(context)\n", in: out), 2)
    }

    func testAnyModeOmitsContextLine() {
        let user = [UserSnippet(trigger: ";a", replacement: "\\alpha", options: SnippetOptions(mode: .any))]
        let out = SnippetComposer.compose(base: base, user: user, disabledBuiltins: [])
        XCTAssertFalse(out.contains("context math(context)"))
    }

    func testFlagsFollowAutoExpand() {
        let auto = UserSnippet(trigger: ";a", replacement: "x", options: SnippetOptions(autoExpand: true))
        let manual = UserSnippet(trigger: ";b", replacement: "y", options: SnippetOptions(autoExpand: false))
        let out = SnippetComposer.compose(base: base, user: [auto, manual], disabledBuiltins: [])
        XCTAssertTrue(out.contains("snippet ;a \";a\" Ai\n"))
        XCTAssertTrue(out.contains("snippet ;b \";b\" i\n"))
    }

    func testDisabledUserSnippetIsOmitted() {
        let user = [UserSnippet(trigger: ";a", replacement: "x", enabled: false)]
        let out = SnippetComposer.compose(base: base, user: user, disabledBuiltins: ["te"])
        XCTAssertFalse(out.contains("snippet ;a"))
        XCTAssertTrue(out.contains("# chalk-disable: te\n"))
    }

    func testDisableLineSortsKeysAndQuotesSpacedRegexSources() {
        let out = SnippetComposer.compose(
            base: base,
            user: [],
            disabledBuiltins: ["te", "([ ]*)sr", "sb"]
        )
        // "([ ]*)sr" contains a space → backtick-quoted; sorted order.
        XCTAssertTrue(out.contains("# chalk-disable: `([ ]*)sr` sb te\n"))
    }

    func testBodyRoundTripsThroughOwnFormat() {
        let user = [UserSnippet(trigger: ";pd", replacement: "\\frac{\\partial $1}{\\partial $2}$0")]
        let out = SnippetComposer.compose(base: "", user: user, disabledBuiltins: [])
        XCTAssertTrue(out.contains("\\frac{\\partial $1}{\\partial $2}$0\nendsnippet\n"))
    }

    // MARK: - Validation

    func testAllQuoteTriggerStillCarriesItsFlags() {
        // The description is the trigger with `"` stripped, and an empty one
        // makes the header `snippet " "" Ai`, which HEADER_RE reads as having
        // no description AND no flags — the shortcut silently loses Auto and
        // becomes Tab-only. Any non-empty description keeps the header
        // parseable.
        let user = [UserSnippet(trigger: "\"", replacement: "\\quad")]
        let out = SnippetComposer.compose(base: base, user: user, disabledBuiltins: [])
        XCTAssertFalse(out.contains("snippet \" \"\" "))
        XCTAssertTrue(out.contains(" Ai\n"))
    }

    func testValidateTrigger() {
        XCTAssertNil(SnippetComposer.validateTrigger(";a"))
        XCTAssertNil(SnippetComposer.validateTrigger("dot."))
        XCTAssertNotNil(SnippetComposer.validateTrigger(""))
        XCTAssertNotNil(SnippetComposer.validateTrigger("a b"))
        XCTAssertNotNil(SnippetComposer.validateTrigger("a\tb"))
        XCTAssertNotNil(SnippetComposer.validateTrigger("a\nb"))
        XCTAssertNotNil(SnippetComposer.validateTrigger("a`b"))
        XCTAssertNotNil(SnippetComposer.validateTrigger(String(repeating: "x", count: 65)))
    }

    func testValidateReplacement() {
        XCTAssertNil(SnippetComposer.validateReplacement("\\alpha"))
        XCTAssertNil(SnippetComposer.validateReplacement("\\frac{$1}{$2}$0"))
        XCTAssertNil(SnippetComposer.validateReplacement("line1\nline2"))
        XCTAssertNil(SnippetComposer.validateReplacement("uses one ` backtick"))
        XCTAssertNotNil(SnippetComposer.validateReplacement(""))
        XCTAssertNotNil(SnippetComposer.validateReplacement("a\nendsnippet extra"))
        XCTAssertNotNil(SnippetComposer.validateReplacement("has ``js`` block"))
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    func testTextModeEmitsInvertedContext() {
        let user = [UserSnippet(
            trigger: "iff", replacement: "if and only if",
            options: SnippetOptions(mode: .text))]
        let out = SnippetComposer.compose(base: base, user: user, disabledBuiltins: [])
        XCTAssertTrue(out.contains("context !math(context)\n"))
    }

    func testRegexTriggerIsBacktickQuoted() {
        let user = [UserSnippet(
            trigger: "([a-z])bar", replacement: "\\bar{#1}",
            options: SnippetOptions(isRegex: true))]
        let out = SnippetComposer.compose(base: base, user: user, disabledBuiltins: [])
        XCTAssertTrue(out.contains("snippet `([a-z])bar` \"([a-z])bar\" Ai\n"))
    }

    func testWholeWordAndLineStartFlags() {
        let user = [UserSnippet(
            trigger: "lim", replacement: "\\lim_{$1}",
            options: SnippetOptions(wholeWord: true, lineStart: true))]
        let out = SnippetComposer.compose(base: base, user: user, disabledBuiltins: [])
        XCTAssertTrue(out.contains("snippet lim \"lim\" Awb\n"))
    }

    func testRetriggeredForkDisablesTheBuiltin() {
        // The fork moved off the built-in's trigger, so nothing the composer
        // emits answers to `@l` — the key is safe and the built-in must go.
        let user = [UserSnippet(
            trigger: "@lam", replacement: "\\lambda",
            overridesBuiltinKey: "@l")]
        let out = SnippetComposer.compose(base: base, user: user, disabledBuiltins: [])
        XCTAssertTrue(out.contains("# chalk-disable: @l\n"))
        XCTAssertTrue(out.contains("snippet @lam \"@lam\" Ai\n"))
    }

    func testSameTriggerForkDoesNotDisableItself() {
        // Editing only a built-in's replacement leaves the trigger alone, so
        // the fork's disable key equals its own trigger. The directive matches
        // on trigger and can't tell built-in from override, so emitting the key
        // would delete both and the shortcut would stop firing entirely.
        // Priority 10 already shadows the built-in — see
        // `hsnips-disable.test.ts` for the parse-side half of this.
        let user = [UserSnippet(
            trigger: ";;", replacement: "^{$0}",
            overridesBuiltinKey: ";;")]
        let out = SnippetComposer.compose(base: base, user: user, disabledBuiltins: [])
        XCTAssertFalse(out.contains("# chalk-disable:"))
        XCTAssertTrue(out.contains("snippet ;; \";;\" Ai\n^{$0}\n"))
    }

    func testExplicitlyDisabledBuiltinReclaimedByAnActiveTrigger() {
        // Same collision by the other route: the built-in was switched off,
        // then a new shortcut claimed its trigger. Emitting the key would
        // delete the new shortcut too, so it is dropped and the priority-10
        // snippet shadows the built-in instead.
        let user = [UserSnippet(trigger: "te", replacement: "\\theta")]
        let out = SnippetComposer.compose(base: base, user: user, disabledBuiltins: ["te"])
        XCTAssertFalse(out.contains("# chalk-disable:"))
        XCTAssertTrue(out.contains("snippet te \"te\" Ai\n"))
    }

    func testDisabledForkStillDisablesTheBuiltin() {
        // Switching a forked built-in off must not resurrect the original —
        // the row reads as "off", so neither may fire.
        let user = [UserSnippet(
            trigger: "@l", replacement: "\\lambda",
            enabled: false, overridesBuiltinKey: "@l")]
        let out = SnippetComposer.compose(base: base, user: user, disabledBuiltins: [])
        XCTAssertTrue(out.contains("# chalk-disable: @l\n"))
        XCTAssertFalse(out.contains("snippet @l"))
    }

    func testValidateRegexTrigger() {
        XCTAssertNil(SnippetComposer.validateTrigger("([a-z])bar", isRegex: true))
        // Regex sources may contain spaces; literal triggers may not.
        XCTAssertNil(SnippetComposer.validateTrigger("([ ]*)sr", isRegex: true))
        XCTAssertNotNil(SnippetComposer.validateTrigger("([ ]*)sr", isRegex: false))
        XCTAssertNotNil(SnippetComposer.validateTrigger("([a-z", isRegex: true))
        XCTAssertNotNil(SnippetComposer.validateTrigger("a`b", isRegex: true))
        XCTAssertNotNil(SnippetComposer.validateTrigger("a\nb", isRegex: true))
    }
}
