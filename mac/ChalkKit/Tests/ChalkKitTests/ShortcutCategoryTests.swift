import XCTest
@testable import ChalkKit

final class ShortcutCategoryTests: XCTestCase {
    /// Five hops: file -> ChalkKitTests -> Tests -> ChalkKit -> ios -> root.
    private func bundledSnippets() throws -> [BuiltinSnippet] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("packages/editor-core/assets/latex.hsnips")
        return HSnipsCatalog.scan(try String(contentsOf: url))
    }

    func testEveryBundledSnippetLandsInExactlyOneCategory() throws {
        let builtins = try bundledSnippets()
        let rail = ShortcutCategory.all(for: builtins).filter { $0 != .yours }
        for builtin in builtins {
            let owners = rail.filter { $0.contains(builtin) }
            XCTAssertEqual(
                owners.count, 1,
                "\(builtin.key) (section \(builtin.section)) has \(owners.count) categories")
        }
    }

    func testCategoryCountsCoverTheWholeFile() throws {
        let builtins = try bundledSnippets()
        let rail = ShortcutCategory.all(for: builtins).filter { $0 != .yours }
        let total = rail.reduce(0) { sum, c in sum + builtins.filter(c.contains).count }
        XCTAssertEqual(total, builtins.count)
    }

    func testRailOrderStartsWithYoursAndHasNoStrayFallbacks() throws {
        let rail = ShortcutCategory.all(for: try bundledSnippets())
        XCTAssertEqual(rail.first, .yours)
        XCTAssertEqual(
            rail.map(\.id),
            ["yours", "greek", "symbols", "operations", "calculus",
             "linear-algebra", "physics", "environments", "delimiters"],
            "an unexpected id means a latex.hsnips banner fell through to the fallback row")
    }

    func testMatricesAreLinearAlgebraAndCasesIsNot() throws {
        let builtins = try bundledSnippets()
        let linalg = ShortcutCategory.curated.first { $0.id == "linear-algebra" }!
        let envs = ShortcutCategory.curated.first { $0.id == "environments" }!
        func category(of key: String) -> ShortcutCategory? {
            guard let b = builtins.first(where: { $0.key == key }) else { return nil }
            return ShortcutCategory.curated.first { $0.contains(b) }
        }
        for key in ["pmat", "bmat", "Bmat", "vmat", "Vmat", "mat", "arr"] {
            XCTAssertEqual(category(of: key), linalg, key)
        }
        XCTAssertEqual(category(of: "case"), envs)
        XCTAssertEqual(category(of: "beg"), envs)
    }

    func testAnUnclaimedSectionGetsItsOwnRow() {
        // The guard against a new latex.hsnips banner silently vanishing.
        let content = """
        ##############################################################################
        # Brand New Section
        ##############################################################################
        snippet zz "new" A
        x
        endsnippet
        """
        let rail = ShortcutCategory.all(for: HSnipsCatalog.scan(content))
        XCTAssertEqual(rail.map(\.title), ["Your Shortcuts", "Brand New Section"])
    }

    func testEmptyCuratedGroupsAreNotShown() {
        let content = """
        ##############################################################################
        # Greek alphabet
        ##############################################################################
        snippet zz "new" A
        x
        endsnippet
        """
        let rail = ShortcutCategory.all(for: HSnipsCatalog.scan(content))
        XCTAssertEqual(rail.map(\.id), ["yours", "greek"])
    }
}
