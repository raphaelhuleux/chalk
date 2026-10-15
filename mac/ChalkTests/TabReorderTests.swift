import XCTest
import ChalkKit
@testable import Chalk

/// moveTab(id:to:) contracts: reorder + republish, index clamping, unknown-id
/// no-op, and active-tab preservation. Drag gestures themselves are per-strip
/// UI and verified manually; this is the model both strips commit into.
final class TabReorderTests: XCTestCase {
    private var editor: EditorContainerViewController!
    private var published: [[TabItem]] = []

    override func setUp() {
        super.setUp()
        editor = EditorContainerViewController()
        editor.onTabsChanged = { [weak self] in self?.published.append($0) }
        editor.loadViewIfNeeded()
        // Three draft tabs: "Untitled", "Untitled 2", "Untitled 3".
        editor.newFile()
        editor.newFile()
        editor.newFile()
        published = []
    }

    private var names: [String] { published.last?.map(\.name) ?? [] }

    func testMoveForwardReordersAndRepublishes() {
        let items = currentItems()
        editor.moveTab(id: items[0].id, to: 2)
        XCTAssertEqual(names, ["Untitled 2", "Untitled 3", "Untitled"])
    }

    func testMoveBackwardReorders() {
        let items = currentItems()
        editor.moveTab(id: items[2].id, to: 0)
        XCTAssertEqual(names, ["Untitled 3", "Untitled", "Untitled 2"])
    }

    func testOutOfRangeIndexClamps() {
        let items = currentItems()
        editor.moveTab(id: items[0].id, to: 99)
        XCTAssertEqual(names, ["Untitled 2", "Untitled 3", "Untitled"])
        editor.moveTab(id: items[0].id, to: -5)
        XCTAssertEqual(names, ["Untitled", "Untitled 2", "Untitled 3"])
    }

    func testUnknownIDDoesNothing() {
        editor.moveTab(id: UUID(), to: 0)
        XCTAssertTrue(published.isEmpty, "no republish expected for unknown id")
    }

    func testSamePositionDoesNotRepublish() {
        let items = currentItems()
        editor.moveTab(id: items[1].id, to: 1)
        XCTAssertTrue(published.isEmpty, "no republish expected for a no-op move")
    }

    func testActiveTabStaysActiveAcrossMove() {
        let items = currentItems()
        // newFile() activates the last-created tab ("Untitled 3").
        XCTAssertTrue(items[2].isActive)
        editor.moveTab(id: items[2].id, to: 0)
        let after = currentItems()
        XCTAssertEqual(after.map(\.name), ["Untitled 3", "Untitled", "Untitled 2"])
        XCTAssertTrue(after[0].isActive)
    }

    private func currentItems() -> [TabItem] { editor.tabItemsForTesting }
}
