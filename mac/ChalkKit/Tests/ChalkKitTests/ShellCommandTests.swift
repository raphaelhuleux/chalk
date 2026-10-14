import XCTest
@testable import ChalkKit

/// `ShellCommand` mirrors `SHELL_COMMANDS` in web/src/native-host.ts, and there is
/// no cross-language fixture to check it against, so this pins the Swift half:
/// the exact four raw values the page can post, and nothing else.
final class ShellCommandTests: XCTestCase {
    /// The raw values as the page spells them, in the same order as the TS list.
    private let wireNames = ["save", "toggle-outline", "toggle-outline-panel", "quick-open"]

    func testEveryWireNameDecodes() throws {
        for name in wireNames {
            XCTAssertNotNil(ShellCommand(rawValue: name), "no ShellCommand for \(name)")
        }
        XCTAssertEqual(ShellCommand.allCases.map(\.rawValue), wireNames)
    }

    func testCaseCountIsFour() {
        XCTAssertEqual(ShellCommand.allCases.count, 4)
    }

    func testUnknownNameDoesNotDecode() {
        XCTAssertNil(ShellCommand(rawValue: "toggleOutline"))
        XCTAssertNil(ShellCommand(rawValue: "open-external"))
        XCTAssertNil(ShellCommand(rawValue: ""))
    }

    /// Codable over the wire spelling, not the Swift case name: the `command`
    /// message carries `{"name": "toggle-outline"}`.
    func testCodableUsesTheWireSpelling() throws {
        for command in ShellCommand.allCases {
            let data = try JSONEncoder().encode(command)
            XCTAssertEqual(String(data: data, encoding: .utf8), "\"\(command.rawValue)\"")
            XCTAssertEqual(try JSONDecoder().decode(ShellCommand.self, from: data), command)
        }
    }
}
