import XCTest
import ChalkKit
@testable import Chalk

/// A tab dragged out of its row: over another group's editor it splits or joins by VS Code's zones,
/// over another row it inserts at the marker, and a cancelled drag changes nothing.
///
/// The strip's drag seams are driven with window points: AppKit vends no constructible mouse
/// drag, and the rules are about where the session ends. Escape itself is a key monitor; these
/// tests drive the `cancelDrag` it calls.
@MainActor
final class TabDragSessionTests: XCTestCase {
    private var window: NSWindow!
    private var root: RootSplitViewController!
    private var editor: EditorContainerViewController { root.editorForTesting }

    override func setUp() {
        super.setUp()
        window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1400, height: 800))
        root = RootSplitViewController(initialContent: .openEmpty)
        root.motionPolicyForTesting = .instant
        window.rootViewController = root
        window.isHidden = false
        root.loadViewIfNeeded()
        root.setSidebarVisible(false)
        root.view.layoutSubtreeIfNeeded()
    }

    override func tearDown() {
        for _ in 0..<editor.tabCountForTesting { editor.closeActiveTab() }
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        root = nil
        super.tearDown()
    }

    /// `tabs` drafts with the last split off into a second group: 3 is a b | c, 2 is a | b.
    private func makeGroups(tabs: Int) {
        for _ in 0..<tabs { editor.newFile() }
        editor.splitRight()
        settle()
    }

    private func settle() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        root.view.layoutSubtreeIfNeeded()
    }

    private var groupSizes: [Int] { editor.groupItemsForTesting.map(\.tabs.count) }
    private func tabID(group: Int, at index: Int) -> UUID { editor.groupItemsForTesting[group].tabs[index].id }
    private func strip(_ group: Int) -> HeaderTabStrip { root.tabStripsForTesting[group] }

    private func windowPoint(inGroup index: Int, fx: CGFloat, fy: CGFloat) -> NSPoint {
        let pane = editor.paneFramesForTesting[index]
        return editor.view.convert(NSPoint(x: pane.minX + pane.width * fx, y: pane.minY + pane.height * fy), to: nil)
    }

    /// Lift `id` from `group`'s row, move through `points`, release at the last one.
    private func drag(_ id: UUID, from group: Int, through points: [NSPoint]) {
        let row = strip(group)
        row.beginReorder(id)
        for point in points { row.dragMoved(toWindowPoint: point) }
        row.endReorder()
        settle()
    }

    func testADropOnAnotherGroupsTrailingEdgeMakesAGroupThere() {
        makeGroups(tabs: 3)
        XCTAssertEqual(groupSizes, [2, 1])
        let moved = tabID(group: 0, at: 0)
        let edge = windowPoint(inGroup: 1, fx: 0.95, fy: 0.5)
        strip(0).beginReorder(moved)
        strip(0).dragMoved(toWindowPoint: edge)
        let shown = editor.dropIndicatorForTesting
        XCTAssertNotNil(shown, "the edge shows where the new group goes")
        if let shown {
            XCTAssertEqual(shown.minX, editor.paneFramesForTesting[1].midX, accuracy: 1, "the trailing half")
        }
        strip(0).endReorder()
        settle()
        XCTAssertNil(editor.dropIndicatorForTesting, "the drop clears the indicator")
        XCTAssertEqual(groupSizes, [1, 1, 1])
        XCTAssertEqual(tabID(group: 2, at: 0), moved)
        XCTAssertEqual(editor.focusedGroupIndexForTesting, 2, "the drop focuses where the tab landed")
    }

    func testADropInAnotherGroupsCenterJoinsIt() {
        makeGroups(tabs: 3)
        let moved = tabID(group: 0, at: 0)
        drag(moved, from: 0, through: [windowPoint(inGroup: 1, fx: 0.5, fy: 0.5)])
        XCTAssertEqual(groupSizes, [1, 2])
        XCTAssertEqual(editor.groupItemsForTesting[1].tabs.last?.id, moved)
        XCTAssertEqual(editor.focusedGroupIndexForTesting, 1)
    }

    func testMovingAGroupsOnlyTabAwayClosesTheGroup() {
        makeGroups(tabs: 2)
        let moved = tabID(group: 1, at: 0)
        drag(moved, from: 1, through: [windowPoint(inGroup: 0, fx: 0.5, fy: 0.5)])
        XCTAssertEqual(groupSizes, [2])
        XCTAssertEqual(root.tabStripsForTesting.filter { !$0.isHidden && $0.superview != nil }.count, 1)
    }

    func testAGroupsOnlyTabOverItsOwnGroupShowsNothingAndDropsNothing() {
        makeGroups(tabs: 2)
        let id = tabID(group: 1, at: 0)
        let edge = windowPoint(inGroup: 1, fx: 0.95, fy: 0.5)
        strip(1).beginReorder(id)
        strip(1).dragMoved(toWindowPoint: edge)
        XCTAssertNil(editor.dropIndicatorForTesting)
        strip(1).endReorder()
        settle()
        XCTAssertEqual(groupSizes, [1, 1])
        XCTAssertEqual(editor.focusedGroupIndexForTesting, 1)
    }

    func testADropOnAnotherRowInsertsAtTheMarker() throws {
        makeGroups(tabs: 3)
        let moved = tabID(group: 0, at: 0)
        let target = tabID(group: 1, at: 0)
        let frame = try XCTUnwrap(strip(1).tabFrameInWindowForTesting(target))
        // Just inside the target's leading edge: before it.
        drag(moved, from: 0, through: [NSPoint(x: frame.minX + 2, y: frame.midY)])
        XCTAssertEqual(groupSizes, [1, 2])
        XCTAssertEqual(editor.groupItemsForTesting[1].tabs.map(\.id), [moved, target])
    }

    func testACancelledDragChangesNothing() {
        makeGroups(tabs: 3)
        let moved = tabID(group: 0, at: 0)
        let edge = windowPoint(inGroup: 1, fx: 0.95, fy: 0.5)
        let before = editor.groupItemsForTesting
        strip(0).beginReorder(moved)
        strip(0).dragMoved(toWindowPoint: edge)
        XCTAssertNotNil(editor.dropIndicatorForTesting)
        strip(0).cancelDrag()
        strip(0).endReorder()
        settle()
        XCTAssertNil(editor.dropIndicatorForTesting)
        XCTAssertEqual(editor.groupItemsForTesting.map { $0.tabs.map(\.id) }, before.map { $0.tabs.map(\.id) })
    }

    /// A lift that wanders down a few points inside its own row and comes back is still a click.
    func testAJitterInsideItsOwnRowIsStillAClick() throws {
        makeGroups(tabs: 3)
        editor.focusGroup(at: 1)
        let first = tabID(group: 0, at: 0)
        let frame = try XCTUnwrap(strip(0).tabFrameInWindowForTesting(first))
        drag(first, from: 0, through: [NSPoint(x: frame.midX + 3, y: frame.midY - 4),
                                       NSPoint(x: frame.midX, y: frame.midY)])
        XCTAssertEqual(groupSizes, [2, 1])
        XCTAssertEqual(editor.focusedGroupIndexForTesting, 0)
        XCTAssertEqual(editor.groupItemsForTesting[0].tabs.first { $0.isActive }?.id, first)
    }
}
