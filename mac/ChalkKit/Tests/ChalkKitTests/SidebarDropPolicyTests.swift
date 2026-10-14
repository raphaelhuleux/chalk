import XCTest
@testable import ChalkKit

/// The Finder rule the sidebar drag-move has to obey: a drop lands in a
/// *directory*, and the row under the pointer only names which one. A file row
/// means "into the folder that holds it" — which is how a file gets dragged
/// back out to a Location's top level.
final class SidebarDropPolicyTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Users/x/Notes")

    func testNoRowIsTheLocationRoot() {
        XCTAssertEqual(SidebarDropPolicy.destination(row: nil, locationRoot: root), .locationRoot,
                       "blank space under a Location's rows drops at its top level")
    }

    func testFolderRowIsThatFolder() {
        let folder = root.appendingPathComponent("Papers")
        XCTAssertEqual(SidebarDropPolicy.destination(row: .folder(folder), locationRoot: root),
                       .folder(folder))
    }

    func testTopLevelFileRowIsTheLocationRoot() {
        let file = root.appendingPathComponent("index.md")
        XCTAssertEqual(SidebarDropPolicy.destination(row: .file(file), locationRoot: root),
                       .locationRoot,
                       "dragging a file onto a sibling at the top level targets the top level")
    }

    func testNestedFileRowIsItsContainingFolder() {
        let folder = root.appendingPathComponent("Papers")
        let file = folder.appendingPathComponent("draft.tex")
        XCTAssertEqual(SidebarDropPolicy.destination(row: .file(file), locationRoot: root),
                       .folder(folder))
    }

    /// The same trap `FileMove.canMove` documents: `deletingLastPathComponent`
    /// leaves a trailing slash, so the root comparison must go through paths.
    func testTrailingSlashRootStillResolvesToTheRoot() {
        let slashed = URL(fileURLWithPath: "/Users/x/Notes/")
        let file = slashed.appendingPathComponent("index.md")
        XCTAssertEqual(SidebarDropPolicy.destination(row: .file(file), locationRoot: slashed),
                       .locationRoot)
        XCTAssertEqual(SidebarDropPolicy.destination(row: .file(file), locationRoot: root),
                       .locationRoot)
    }

    func testUnstandardizedPathsCompareEqual() {
        let noisy = URL(fileURLWithPath: "/Users/x/Notes/Papers/../index.md")
        XCTAssertEqual(SidebarDropPolicy.destination(row: .file(noisy), locationRoot: root),
                       .locationRoot)
    }

    /// Defensive: a folder row that *is* the Location root reads as the root, so
    /// the highlight lands on the header rather than hunting for a row that
    /// does not exist.
    func testFolderRowEqualToRootIsTheRoot() {
        XCTAssertEqual(SidebarDropPolicy.destination(row: .folder(root), locationRoot: root),
                       .locationRoot)
    }
}
