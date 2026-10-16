import XCTest
@testable import ChalkKit

/// Runs `vscode/test/fixtures/latex-roots.json`, the cases the VS Code
/// extension's root finder also runs (`latex-root-parity.test.ts`). A rule
/// change must land in both finders, and its case there.
final class LatexRootParityTests: XCTestCase {
    private struct Case: Decodable {
        struct Options: Decodable {
            var configuredRoot: String?
            var workspaceDir: String?
            var preferredRoot: String?
        }
        var name: String
        var files: [String: String]
        var fls: [String: [String]]?
        var saved: String
        var options: Options
        var root: String?
        var reasonContains: String?
    }

    private struct Fixture: Decodable { var cases: [Case] }

    private func loadCases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../vscode/test/fixtures/latex-roots.json")
            .standardizedFileURL
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).cases
    }

    func testSharedCases() throws {
        let cases = try loadCases()
        XCTAssertGreaterThan(cases.count, 10)
        for c in cases {
            let fs = LatexRoot.FileSystem(
                readFile: { c.files[$0] },
                exists: { c.files[$0] != nil },
                listTexFiles: { c.files.keys.filter { $0.hasSuffix(".tex") }.sorted() },
                flsInputs: { c.fls?[$0] ?? [] }
            )
            let r = LatexRoot.find(
                saved: c.saved,
                fs: fs,
                options: .init(
                    configuredRoot: c.options.configuredRoot,
                    workspaceDir: c.options.workspaceDir,
                    preferredRoot: c.options.preferredRoot
                )
            )
            XCTAssertEqual(r.root, c.root, c.name)
            if let needle = c.reasonContains {
                XCTAssertTrue(r.reason.contains(needle), "\(c.name): reason \"\(r.reason)\" lacks \"\(needle)\"")
            }
        }
    }

    func testParsesFlsInputsAgainstPWD() {
        let fls = "PWD /ws/paper\nINPUT /usr/texmf.cnf\nINPUT main.tex\nINPUT ./sections/intro.tex\nINPUT ./sections/intro.tex\nOUTPUT main.aux\n"
        XCTAssertEqual(LatexRoot.parseFlsInputs(fls), ["/usr/texmf.cnf", "/ws/paper/main.tex", "/ws/paper/sections/intro.tex"])
    }

    func testIncludedTexFilesFollowsTheClosure() {
        let files = [
            "/ws/main.tex": "\\documentclass{article}\n\\input{sections/intro}\n% \\input{commented}\n",
            "/ws/sections/intro.tex": "\\import{shared/}{macros}\n",
            "/ws/shared/macros.tex": "\\input{sections/intro}\n",
        ]
        let fs = LatexRoot.FileSystem(readFile: { files[$0] }, exists: { files[$0] != nil }, listTexFiles: { [] })
        XCTAssertEqual(LatexRoot.includedTexFiles("/ws/main.tex", fs), ["/ws/main.tex", "/ws/sections/intro.tex", "/ws/shared/macros.tex"])
    }
}
