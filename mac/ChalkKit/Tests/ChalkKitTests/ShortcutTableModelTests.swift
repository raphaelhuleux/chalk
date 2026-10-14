import XCTest
@testable import ChalkKit

final class ShortcutTableModelTests: XCTestCase {
    private let lambda = BuiltinSnippet(
        key: "@l", display: "@l", description: "lambda",
        replacement: "\\lambda", options: SnippetOptions())
    private let bar = BuiltinSnippet(
        key: "([a-z])bar", display: "([a-z])bar", description: "add bar",
        replacement: "\\bar{#1}", options: SnippetOptions(isRegex: true))

    func testBuiltinsRenderAsRowsWhenNothingIsOverridden() {
        let sections = ShortcutTableModel.rows(
            user: [], builtins: [lambda, bar], disabledBuiltinKeys: [], query: "")
        XCTAssertTrue(sections.yours.isEmpty)
        XCTAssertEqual(sections.builtin.map(\.trigger), ["@l", "([a-z])bar"])
        XCTAssertFalse(sections.builtin[0].isModified)
        XCTAssertTrue(sections.builtin[0].isEnabled)
    }

    func testDisabledKeyTurnsTheRowOff() {
        let sections = ShortcutTableModel.rows(
            user: [], builtins: [lambda], disabledBuiltinKeys: ["@l"], query: "")
        XCTAssertFalse(sections.builtin[0].isEnabled)
    }

    func testForkSeedsFromTheBuiltin() {
        let fork = ShortcutTableModel.fork(bar)
        XCTAssertEqual(fork.trigger, "([a-z])bar")
        XCTAssertEqual(fork.replacement, "\\bar{#1}")
        XCTAssertTrue(fork.options.isRegex)
        XCTAssertEqual(fork.overridesBuiltinKey, "([a-z])bar")
        XCTAssertTrue(fork.enabled)
    }

    func testForkRendersInPlaceInTheBuiltinSection() {
        var fork = ShortcutTableModel.fork(lambda)
        fork.replacement = "\\Lambda"
        let sections = ShortcutTableModel.rows(
            user: [fork], builtins: [lambda, bar], disabledBuiltinKeys: [], query: "")
        // Forks never move to "Your Shortcuts" — the row stays put.
        XCTAssertTrue(sections.yours.isEmpty)
        XCTAssertEqual(sections.builtin.map(\.trigger), ["@l", "([a-z])bar"])
        XCTAssertEqual(sections.builtin[0].replacement, "\\Lambda")
        XCTAssertTrue(sections.builtin[0].isModified)
    }

    func testForkEnabledStateComesFromTheFork() {
        var fork = ShortcutTableModel.fork(lambda)
        fork.enabled = false
        let sections = ShortcutTableModel.rows(
            user: [fork], builtins: [lambda], disabledBuiltinKeys: [], query: "")
        XCTAssertFalse(sections.builtin[0].isEnabled)
    }

    func testOrphanedForkFallsBackToYourShortcuts() {
        // The built-in it referenced is gone from a newer bundled file.
        var fork = ShortcutTableModel.fork(lambda)
        fork.trigger = ";lam"
        let sections = ShortcutTableModel.rows(
            user: [fork], builtins: [bar], disabledBuiltinKeys: [], query: "")
        XCTAssertEqual(sections.yours.map(\.trigger), [";lam"])
    }

    func testQueryFiltersBothSectionsOnTriggerAndReplacement() {
        let own = UserSnippet(trigger: ";pd", replacement: "\\partial")
        let sections = ShortcutTableModel.rows(
            user: [own], builtins: [lambda, bar], disabledBuiltinKeys: [], query: "lambda")
        XCTAssertTrue(sections.yours.isEmpty)
        XCTAssertEqual(sections.builtin.map(\.trigger), ["@l"])

        let byTrigger = ShortcutTableModel.rows(
            user: [own], builtins: [lambda, bar], disabledBuiltinKeys: [], query: "PD")
        XCTAssertEqual(byTrigger.yours.map(\.trigger), [";pd"])
        XCTAssertTrue(byTrigger.builtin.isEmpty)
    }

    func testQueryAlsoMatchesBuiltinDescriptions() {
        let sections = ShortcutTableModel.rows(
            user: [], builtins: [lambda, bar], disabledBuiltinKeys: [], query: "add bar")
        XCTAssertEqual(sections.builtin.map(\.trigger), ["([a-z])bar"])
    }

    // MARK: - Row identity

    func testRowsCarryAnIdentityForTheirSource() {
        let own = UserSnippet(trigger: ";pd", replacement: "\\partial")
        let sections = ShortcutTableModel.rows(
            user: [own], builtins: [lambda], disabledBuiltinKeys: [], query: "")
        XCTAssertEqual(sections.yours[0].identity, .user(own.id))
        XCTAssertEqual(sections.builtin[0].identity, .builtin("@l"))
    }

    func testForkingABuiltinKeepsTheRowIdentity() {
        // The identity a cell was configured with before the fork must still
        // name the same row after it — the fork is the same row, edited.
        let before = ShortcutTableModel.rows(
            user: [], builtins: [lambda], disabledBuiltinKeys: [], query: "")
        var fork = ShortcutTableModel.fork(lambda)
        fork.trigger = "@L"
        let after = ShortcutTableModel.rows(
            user: [fork], builtins: [lambda], disabledBuiltinKeys: [], query: "")
        XCTAssertEqual(before.builtin[0].identity, after.builtin[0].identity)
        XCTAssertNotEqual(fork.id, lambda.key) // not identity by stored id
    }

    func testLookupResolvesRowsByIdentityRegardlessOfPosition() {
        let own = UserSnippet(trigger: ";pd", replacement: "\\partial")
        let sections = ShortcutTableModel.rows(
            user: [own], builtins: [lambda, bar], disabledBuiltinKeys: [], query: "")
        let found = ShortcutTableModel.row(
            .builtin("([a-z])bar"), yours: sections.yours, builtin: sections.builtin)
        XCTAssertEqual(found?.trigger, "([a-z])bar")

        // Same identity, different index: prepending a row must not move it.
        let shifted = ShortcutTableModel.rows(
            user: [own], builtins: [bar], disabledBuiltinKeys: [], query: "")
        let again = ShortcutTableModel.row(
            .builtin("([a-z])bar"), yours: shifted.yours, builtin: shifted.builtin)
        XCTAssertEqual(again?.trigger, "([a-z])bar")
        XCTAssertEqual(
            ShortcutTableModel.row(
                .user(own.id), yours: sections.yours, builtin: sections.builtin)?.trigger,
            ";pd")
    }

    func testLookupCannotResolveARowAfterTheCategorySliceSwaps() {
        // A category swap replaces `yours`/`builtin` with another rail row's
        // slice, and an identity from the old slice no longer resolves. This
        // is why the view controller must commit an in-flight field edit
        // BEFORE reloading for a new category: a blur delivered after the
        // swap looks its identity up against these arrays, gets nil, and the
        // edit is silently dropped.
        let greekLambda = BuiltinSnippet(
            key: "@l", display: "@l", description: "lambda",
            replacement: "\\lambda", options: SnippetOptions(), section: "Greek alphabet")
        let integral = BuiltinSnippet(
            key: "dint", display: "dint", description: "definite integral",
            replacement: "\\int_{$1}^{$2} $0", options: SnippetOptions(), section: "Integrals")
        let greek = ShortcutCategory(
            id: "greek", title: "Greek letters", symbol: "textformat",
            sections: ["Greek alphabet"])
        let calculus = ShortcutCategory(
            id: "calculus", title: "Calculus", symbol: "function",
            sections: ["Integrals"])

        let before = ShortcutTableModel.rows(
            user: [], builtins: [greekLambda, integral], disabledBuiltinKeys: [],
            query: "", category: greek)
        let identity = before.builtin[0].identity
        XCTAssertNotNil(ShortcutTableModel.row(
            identity, yours: before.yours, builtin: before.builtin))

        let after = ShortcutTableModel.rows(
            user: [], builtins: [greekLambda, integral], disabledBuiltinKeys: [],
            query: "", category: calculus)
        XCTAssertNil(ShortcutTableModel.row(
            identity, yours: after.yours, builtin: after.builtin))
    }

    func testLookupReturnsNilForTheAddRowAndForVanishedRows() {
        let sections = ShortcutTableModel.rows(
            user: [], builtins: [lambda], disabledBuiltinKeys: [], query: "")
        XCTAssertNil(ShortcutTableModel.row(
            .addRow, yours: sections.yours, builtin: sections.builtin))
        XCTAssertNil(ShortcutTableModel.row(
            .user("deleted"), yours: sections.yours, builtin: sections.builtin))
    }

    func testDuplicateForksOfTheSameBuiltinDoNotLoseTheLoser() {
        // A corrupt or synced store could produce two forks of one built-in.
        // The later one in `user` wins the built-in row; the earlier one
        // must still show up somewhere rather than disappearing.
        var first = ShortcutTableModel.fork(lambda)
        first.replacement = "\\lambda_1"
        var second = ShortcutTableModel.fork(lambda)
        second.replacement = "\\lambda_2"
        let sections = ShortcutTableModel.rows(
            user: [first, second], builtins: [lambda], disabledBuiltinKeys: [], query: "")
        XCTAssertEqual(sections.builtin.map(\.replacement), ["\\lambda_2"])
        XCTAssertEqual(sections.yours.map(\.replacement), ["\\lambda_1"])
    }
}
