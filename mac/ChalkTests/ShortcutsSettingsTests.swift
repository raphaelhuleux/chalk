import XCTest
import ChalkKit
@testable import Chalk

/// The LaTeX Shortcuts pane against a library over its own defaults suite:
/// the add row under Yours, forking a built-in on first edit, Reset bringing
/// it back, enabling and disabling, the options menu, and search.
@MainActor
final class ShortcutsSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var library: SnippetLibrary!
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "chalk-shortcuts-\(UUID().uuidString)")
        library = SnippetLibrary(store: UserSnippetStore(defaults: defaults, key: "snippets"))
    }

    override func tearDown() {
        for window in windows { dismantleHostedSidebar(window) }
        windows = []
        super.tearDown()
    }

    private func makePane(category: ShortcutCategory = .yours) -> ShortcutsSettingsViewController {
        let vc = ShortcutsSettingsViewController(library: library)
        vc.selectedCategory = category
        vc.loadViewIfNeeded()
        return vc
    }

    private func firstBuiltin(_ vc: ShortcutsSettingsViewController) throws -> ShortcutRow {
        try XCTUnwrap(vc.builtinForTesting.first, "the bundled catalogue must list something")
    }

    /// Lands the deferred reload the real runloop would.
    private func settle(_ vc: ShortcutsSettingsViewController) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        vc.flushReloadForTesting()
    }

    func testYoursOffersTheAddRowAndNothingElseWhenEmpty() {
        let vc = makePane()
        XCTAssertTrue(vc.yoursForTesting.isEmpty)
        XCTAssertEqual(vc.tableRowsForTesting.first, .header(title: "Your Shortcuts", showsColumns: true))
        XCTAssertTrue(vc.tableRowsForTesting.contains(.addRow))
    }

    func testTypingInTheAddRowCreatesAShortcut() {
        let vc = makePane()
        vc.editForTesting(.addRow, trigger: "zz", replacement: "\\zeta")
        settle(vc)
        XCTAssertEqual(vc.yoursForTesting.map(\.trigger), ["zz"])
        XCTAssertEqual(library.store.snippets().map(\.replacement), ["\\zeta"])
        XCTAssertTrue(vc.tableRowsForTesting.contains(.addRow), "the add row stays for the next one")
    }

    func testEditingABuiltinForksItAndResetBringsItBack() throws {
        let vc = makePane(category: ShortcutCategory.curated[0])
        let builtin = try firstBuiltin(vc)
        XCTAssertFalse(builtin.isModified)

        vc.editForTesting(builtin.identity, trigger: builtin.trigger, replacement: "changed")
        settle(vc)
        let forked = try XCTUnwrap(vc.builtinForTesting.first { $0.trigger == builtin.trigger })
        XCTAssertTrue(forked.isModified, "an edited built-in reads as modified")
        XCTAssertEqual(forked.replacement, "changed")
        XCTAssertEqual(ShortcutsSettingsViewController.removalTitle(for: forked), "Reset")

        vc.removeForTesting(forked.identity)
        settle(vc)
        let restored = try XCTUnwrap(vc.builtinForTesting.first { $0.trigger == builtin.trigger })
        XCTAssertFalse(restored.isModified)
        XCTAssertEqual(restored.replacement, builtin.replacement)
        XCTAssertNil(ShortcutsSettingsViewController.removalTitle(for: restored), "a built-in has nothing to reset")
    }

    func testDisablingABuiltinUsesTheStoresDisableSet() throws {
        let vc = makePane(category: ShortcutCategory.curated[0])
        let builtin = try firstBuiltin(vc)
        vc.setEnabledForTesting(builtin.identity, false)
        settle(vc)
        guard case .builtin(let source) = builtin.source else { return XCTFail("expected a built-in") }
        XCTAssertTrue(library.store.disabledBuiltinKeys().contains(source.key))
        XCTAssertEqual(vc.builtinForTesting.first { $0.trigger == builtin.trigger }?.isEnabled, false)
        XCTAssertTrue(library.store.snippets().isEmpty, "disabling does not fork")
    }

    func testOptionsChangeForksAndPersists() throws {
        let vc = makePane(category: ShortcutCategory.curated[0])
        let builtin = try firstBuiltin(vc)
        var options = builtin.options
        options.lineStart.toggle()
        vc.setOptionsForTesting(builtin.identity, options)
        settle(vc)
        let forked = try XCTUnwrap(vc.builtinForTesting.first { $0.trigger == builtin.trigger })
        XCTAssertEqual(forked.options.lineStart, options.lineStart)
        XCTAssertTrue(forked.isModified)
    }

    func testADuplicateTriggerIsRefused() {
        let vc = makePane()
        vc.editForTesting(.addRow, trigger: "zz", replacement: "one")
        settle(vc)
        vc.editForTesting(.addRow, trigger: "zz", replacement: "two")
        settle(vc)
        XCTAssertEqual(vc.yoursForTesting.count, 1)
        XCTAssertEqual(vc.lastErrorForTesting, "You already have a shortcut with this trigger.")
    }

    func testSearchIgnoresTheCategoryAndHidesTheAddRow() throws {
        let vc = makePane()
        let anyBuiltin = try XCTUnwrap(library.builtins.first)
        vc.setQueryForTesting(anyBuiltin.display)
        XCTAssertFalse(vc.tableRowsForTesting.contains(.addRow))
        XCTAssertTrue(vc.builtinForTesting.contains { $0.trigger == anyBuiltin.display })
        vc.setQueryForTesting("")
        XCTAssertTrue(vc.tableRowsForTesting.contains(.addRow))
    }

    /// Every mutation pushes once, coalesced, and a flush lands a pending push now.
    func testMutationsPushTheComposedSnippetsOnce() {
        let vc = makePane()
        var pushes = 0
        vc.onSnippetsChange = { pushes += 1 }
        vc.editForTesting(.addRow, trigger: "aa", replacement: "one")
        settle(vc)
        vc.editForTesting(.addRow, trigger: "bb", replacement: "two")
        vc.flushPendingPush()
        XCTAssertEqual(pushes, 1, "the two edits coalesce into one push")
        vc.flushPendingPush()
        XCTAssertEqual(pushes, 1, "nothing pending, nothing pushed")
    }

    /// Hosted, the rows render the columns: trigger, replacement, options and the removal control.
    func testHostedRowsRenderTheirColumns() throws {
        let vc = makePane()
        vc.editForTesting(.addRow, trigger: "zz", replacement: "\\zeta")
        settle(vc)
        let window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 760, height: 600))
        window.rootViewController = vc
        window.isHidden = false
        vc.view.layoutSubtreeIfNeeded()
        windows.append(window)
        let table = vc.tableViewForTesting
        let index = try XCTUnwrap(vc.tableRowsForTesting.firstIndex { if case .shortcut = $0 { return true }; return false })
        let row = try XCTUnwrap(table.view(atColumn: 0, row: index, makeIfNecessary: true) as? ShortcutRowView)
        XCTAssertEqual(row.triggerFieldForTesting.stringValue, "zz")
        XCTAssertEqual(row.replacementFieldForTesting.stringValue, "\\zeta")
        XCTAssertEqual(row.removalTitleForTesting, "Delete")
        XCTAssertTrue(row.isEnabledForTesting)
        XCTAssertFalse(row.optionsTitleForTesting.isEmpty)
    }
}
