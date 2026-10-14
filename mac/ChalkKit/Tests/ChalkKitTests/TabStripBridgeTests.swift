import XCTest
@testable import ChalkKit

/// Guards on the bridge vocabulary itself.
///
/// Two notification names that collide deliver each other's payloads, and the
/// receivers decode by optional cast — so a collision does not throw, it just
/// makes one lane silently no-op. Cheap to assert, invisible otherwise.
final class TabStripBridgeTests: XCTestCase {
    func testEveryBridgeNameIsUniqueAndNamespaced() {
        let raw = TabStripBridge.allNames.map(\.rawValue)
        XCTAssertEqual(Set(raw).count, raw.count,
                       "two bridge messages share a name: \(raw.sorted())")
        for name in raw {
            XCTAssertTrue(name.hasPrefix("chalk."),
                          "\(name) is not in Chalk's notification namespace")
        }
    }

    /// `allNames` is hand-maintained, so it can fall behind the declarations
    /// it exists to check. This counts the `Notification.Name(` literals in
    /// the source and demands the list cover all of them.
    func testTheNameListCoversEveryDeclaredName() throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent(
            "mac/ChalkKit/Sources/ChalkKit/TabStripBridge.swift"))
        let declared = source.components(separatedBy: "Notification.Name(\"").count - 1
        XCTAssertEqual(declared, TabStripBridge.allNames.count,
                       "TabStripBridge declares \(declared) names but allNames lists "
                       + "\(TabStripBridge.allNames.count) — add the new one to the list")
    }

    /// `#filePath` is .../mac/ChalkKit/Tests/ChalkKitTests/TabStripBridgeTests.swift;
    /// five hops up reach the repo root (as in PaletteParityTests).
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
