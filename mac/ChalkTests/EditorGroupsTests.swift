import XCTest
import ChalkKit
@testable import Chalk

/// Side-by-side tab groups (VS Code's editor groups): each group has its own tabs and shows one;
/// a tab lives in one group; ⌘\ and drops move tabs between groups; a group's last tab takes the
/// group with it.
@MainActor
final class EditorGroupsTests: XCTestCase {
    private var window: NSWindow!
    private var editor: EditorContainerViewController!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1200, height: 700))
        window.isHidden = false
        editor = EditorContainerViewController()
        editor.motionIsInstantForTesting = true
        window.rootViewController = editor
        editor.loadViewIfNeeded()
        window.layoutIfNeeded()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-groups-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        editor = nil
        super.tearDown()
    }

    @discardableResult
    private func open(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
        editor.open(url: url)
        return url
    }

    private func settle() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        window.layoutIfNeeded()
    }

    private func id(ofTabAt index: Int) -> UUID { editor.tabItemsForTesting[index].id }
    private func groupID(_ index: Int) -> UUID { editor.groupItemsForTesting[index].id }
    private var groupNames: [[String]] { editor.groupItemsForTesting.map { $0.tabs.map(\.name) } }

    /// A point in group `index`'s pane, at `(fx, fy)` of its size, in window coordinates.
    private func windowPoint(inGroup index: Int, fx: CGFloat, fy: CGFloat) -> NSPoint {
        let pane = editor.paneFramesForTesting[index]
        let local = NSPoint(x: pane.minX + pane.width * fx, y: pane.minY + pane.height * fy)
        return editor.view.convert(local, to: nil)
    }

    // MARK: Splitting

    func testSplitRightMovesTheFocusedTabIntoANewGroup() throws {
        try open("a.md")
        try open("b.md")
        editor.splitRight()
        settle()
        XCTAssertEqual(groupNames, [["a.md"], ["b.md"]])
        XCTAssertEqual(editor.focusedGroupIndexForTesting, 1, "focus follows the moved tab")
        XCTAssertEqual(editor.paneGroupIndexForTesting(tabAt: 0), 0)
        XCTAssertEqual(editor.paneGroupIndexForTesting(tabAt: 1), 1)
        let panes = editor.paneFramesForTesting
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes[0].width, panes[1].width, accuracy: 1, "a split halves the group it splits")
    }

    func testAGroupCannotGiveAwayItsOnlyTab() throws {
        try open("a.md")
        XCTAssertFalse(editor.canSplitRight)
        editor.splitRight()
        XCTAssertEqual(editor.groupCount, 1)
    }

    func testNoNewGroupWhereItCannotKeepItsFloor() throws {
        for name in ["a.md", "b.md", "c.md", "d.md"] { try open(name) }
        editor.splitRight()
        editor.focusGroup(at: 0)
        editor.splitRight()
        settle()
        XCTAssertEqual(editor.groupCount, 3)
        editor.focusGroup(at: 0)
        XCTAssertFalse(editor.canSplitRight, "four groups of the floor width do not fit 1200pt")
    }

    func testEachGroupShowsItsOwnTab() throws {
        try open("a.md")
        try open("b.md")
        editor.splitRight()
        let groups = editor.groupItemsForTesting
        XCTAssertEqual(groups.map { $0.tabs.map(\.isActive) }, [[true], [true]])
        XCTAssertEqual(groups.map(\.isFocused), [false, true])
    }

    // MARK: Focus

    func testAChipClickLoadsItsOwnGroup() throws {
        try open("a.md")
        try open("b.md")
        try open("c.md")
        editor.splitRight() // a b | c
        settle()
        editor.activate(id: id(ofTabAt: 0))
        settle()
        XCTAssertEqual(editor.focusedGroupIndexForTesting, 0)
        XCTAssertEqual(editor.groupActiveTabIndicesForTesting, [0, 2], "the other group keeps its tab")
        XCTAssertNil(editor.paneGroupIndexForTesting(tabAt: 1), "the replaced tab leaves the pane")
    }

    func testOpeningAFileShownInAnotherGroupFocusesThatGroup() throws {
        try open("a.md")
        try open("b.md")
        let c = try open("c.md")
        editor.splitRight() // a b | c
        editor.focusGroup(at: 0)
        editor.open(url: c)
        settle()
        XCTAssertEqual(editor.tabCountForTesting, 3, "no second tab for the same file")
        XCTAssertEqual(editor.focusedGroupIndexForTesting, 1)
        XCTAssertEqual(editor.paneGroupIndexForTesting(tabAt: 2), 1, "focus moves; surfaces stay")
    }

    func testAClickInAnotherPaneFocusesItsGroup() throws {
        try open("a.md")
        try open("b.md")
        editor.splitRight() // a | b
        editor.focusPaneForTesting(group: 0)
        XCTAssertEqual(editor.focusedGroupIndexForTesting, 0)
        XCTAssertEqual(editor.activeTabIndexForTesting, 0)
    }

    func testFocusNextGroupWraps() throws {
        try open("a.md")
        try open("b.md")
        editor.splitRight()
        editor.focusNextGroup()
        XCTAssertEqual(editor.focusedGroupIndexForTesting, 0)
        editor.focusNextGroup()
        XCTAssertEqual(editor.focusedGroupIndexForTesting, 1)
        XCTAssertFalse(editor.focusGroup(at: 5))
    }

    func testCyclingStaysInTheFocusedGroup() throws {
        try open("a.md")
        try open("b.md")
        try open("c.md")
        editor.splitRight() // a b | c
        editor.focusGroup(at: 0) // b
        editor.nextTab()
        XCTAssertEqual(editor.activeTabIndexForTesting, 0, "b wraps to a, never to c in the other group")
        XCTAssertEqual(editor.focusedGroupIndexForTesting, 0)
    }

    // MARK: Moving tabs between groups

    func testMoveToTheRightGroupMakesOneWhenThereIsNone() throws {
        try open("a.md")
        try open("b.md")
        try open("c.md")
        editor.moveToNeighborGroup(id: id(ofTabAt: 0), trailing: true)
        settle()
        XCTAssertEqual(groupNames, [["b.md", "c.md"], ["a.md"]])
        XCTAssertEqual(editor.focusedGroupIndexForTesting, 1)
        editor.moveToNeighborGroup(id: id(ofTabAt: 0), trailing: true) // b joins a
        XCTAssertEqual(groupNames, [["c.md"], ["a.md", "b.md"]])
    }

    func testMovingAGroupsLastTabClosesTheGroup() throws {
        try open("a.md")
        try open("b.md")
        editor.splitRight() // a | b
        editor.moveTab(id: id(ofTabAt: 0), toGroup: groupID(1), at: 0)
        settle()
        XCTAssertEqual(groupNames, [["a.md", "b.md"]])
        XCTAssertEqual(editor.activeTabIndexForTesting, 0, "the moved tab is shown and focused")
        XCTAssertEqual(editor.paneFramesForTesting, [editor.contentViewFrameForTesting])
    }

    func testJoinAllGroupsKeepsStripOrder() throws {
        try open("a.md")
        try open("b.md")
        try open("c.md")
        editor.splitRight()
        editor.focusGroup(at: 0)
        editor.splitRight() // a | b | c
        XCTAssertEqual(editor.groupCount, 3)
        editor.joinAllGroups()
        settle()
        XCTAssertEqual(groupNames, [["a.md", "b.md", "c.md"]])
        XCTAssertEqual(editor.paneFramesForTesting.count, 1)
    }

    // MARK: Drop zones (VS Code's editorDropTarget)

    func testDropZonesOverAnotherGroup() throws {
        try open("a.md")
        try open("b.md")
        try open("c.md")
        editor.splitRight() // a b | c
        settle()
        let a = id(ofTabAt: 0)
        XCTAssertEqual(editor.dropTarget(forTab: a, atWindowPoint: windowPoint(inGroup: 1, fx: 0.5, fy: 0.5))?.zone,
                       .center)
        XCTAssertEqual(editor.dropTarget(forTab: a, atWindowPoint: windowPoint(inGroup: 1, fx: 0.05, fy: 0.5))?.zone,
                       .leading)
        XCTAssertEqual(editor.dropTarget(forTab: a, atWindowPoint: windowPoint(inGroup: 1, fx: 0.95, fy: 0.5))?.zone,
                       .trailing)
        XCTAssertEqual(editor.dropTarget(forTab: a, atWindowPoint: windowPoint(inGroup: 0, fx: 0.6, fy: 0.5))?.zone,
                       .trailing, "its own group splits by halves, with no dead middle")
        XCTAssertEqual(editor.dropTarget(forTab: a, atWindowPoint: windowPoint(inGroup: 0, fx: 0.05, fy: 0.5))?.zone,
                       .leading, "its own group splits while another tab stays behind")
        let c = id(ofTabAt: 2)
        XCTAssertNil(editor.dropTarget(forTab: c, atWindowPoint: windowPoint(inGroup: 1, fx: 0.95, fy: 0.5)),
                     "a group's only tab has nowhere to go in its own group")
    }

    func testDropOnAnEdgeSplitsTheTarget() throws {
        try open("a.md")
        try open("b.md")
        try open("c.md")
        editor.splitRight() // a b | c
        editor.dropTab(id: id(ofTabAt: 0), onGroup: groupID(1), zone: .trailing)
        settle()
        XCTAssertEqual(groupNames, [["b.md"], ["c.md"], ["a.md"]])
        XCTAssertEqual(editor.focusedGroupIndexForTesting, 2)
        XCTAssertEqual(editor.paneFramesForTesting.count, 3)
    }

    func testDropInTheCenterJoinsTheGroup() throws {
        try open("a.md")
        try open("b.md")
        editor.splitRight() // a | b
        editor.dropTab(id: id(ofTabAt: 1), onGroup: groupID(0), zone: .center)
        settle()
        XCTAssertEqual(groupNames, [["a.md", "b.md"]])
        XCTAssertEqual(editor.activeTabIndexForTesting, 1)
    }

    // MARK: Closing tabs

    func testClosingAGroupsLastTabClosesTheGroup() throws {
        try open("a.md")
        try open("b.md")
        editor.splitRight() // a | b
        editor.closeActiveTab()
        settle()
        XCTAssertEqual(editor.groupCount, 1)
        XCTAssertEqual(editor.activeTabIndexForTesting, 0, "focus goes to the group that took the width")
        XCTAssertEqual(editor.paneFramesForTesting, [editor.contentViewFrameForTesting])
    }

    func testClosingAnUnfocusedGroupsShownTabShowsItsNeighbour() throws {
        try open("a.md")
        try open("b.md")
        try open("c.md")
        editor.splitRight() // a b | c, c focused
        editor.closeTab(id: id(ofTabAt: 1))
        settle()
        XCTAssertEqual(groupNames, [["a.md"], ["c.md"]])
        XCTAssertEqual(editor.groupActiveTabIndicesForTesting, [0, 1])
        XCTAssertEqual(editor.focusedGroupIndexForTesting, 1, "focus stays where it was")
        XCTAssertEqual(editor.paneGroupIndexForTesting(tabAt: 0), 0)
    }

    // MARK: The trailing slot follows focus

    func testTheOutlineFollowsTheFocusedGroup() throws {
        try open("a.md")
        try open("b.md")
        editor.showTrailingPanel(.outline, animated: false)
        editor.splitRight() // a | b
        XCTAssertEqual(editor.outlineSubscriptionForTesting(tabAt: 1), true)
        XCTAssertEqual(editor.outlineSubscriptionForTesting(tabAt: 0), false)
        editor.focusGroup(at: 0)
        XCTAssertEqual(editor.outlineSubscriptionForTesting(tabAt: 0), true)
        XCTAssertEqual(editor.outlineSubscriptionForTesting(tabAt: 1), false)
    }

    func testThePDFFollowsTheFocusedGroupsTab() throws {
        try open("a.tex")
        try open("b.md")
        editor.splitRight() // a | b
        editor.focusGroup(at: 0)
        editor.showTrailingPanel(.pdf, animated: false)
        XCTAssertTrue(editor.isPDFPanelShowing)
        editor.focusGroup(at: 1) // b has no PDF, and no outline is wanted
        XCTAssertFalse(editor.isPDFPanelShowing)
        editor.focusGroup(at: 0)
        XCTAssertTrue(editor.isPDFPanelShowing, "a's PDF comes back with focus")
    }

    // MARK: The seams

    func testADividerMovesOnlyItsNeighboursAndKeepsTheFloor() throws {
        try open("a.md")
        try open("b.md")
        editor.splitRight()
        settle()
        let column = editor.contentViewFrameForTesting.width
        editor.dragGroupDividerForTesting(seam: 0, by: 100)
        XCTAssertEqual(editor.paneFramesForTesting[0].width, column / 2 + 100, accuracy: 1)
        XCTAssertEqual(editor.groupFractionsForTesting[0], (column / 2 + 100) / column, accuracy: 0.01)

        editor.dragGroupDividerForTesting(seam: 0, by: -column)
        XCTAssertGreaterThanOrEqual(editor.paneFramesForTesting[0].width, ChalkMetrics.groupMinimumWidth - 0.5)
    }

    // MARK: Session

    func testTheSessionRecordsEachGroup() throws {
        try open("a.md")
        try open("b.md")
        try open("c.md")
        editor.splitRight() // a b | c
        editor.focusGroup(at: 0)
        let session = editor.sessionGroups()
        XCTAssertEqual(session.groups.map { $0.tabs.map { URL(fileURLWithPath: $0.path).lastPathComponent } },
                       [["a.md", "b.md"], ["c.md"]])
        XCTAssertEqual(session.groups.map(\.activeIndex), [1, 0])
        XCTAssertEqual(session.activeGroupIndex, 0)
        XCTAssertEqual(session.groups.map(\.fraction).reduce(0, +), 1, accuracy: 0.001)
    }

    func testRestoreRebuildsTheGroups() throws {
        let urls = try ["a.md", "b.md", "c.md"].map { name -> URL in
            let url = tempDir.appendingPathComponent(name)
            try "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        editor.restoreGroups([(urls: [urls[0], urls[1]], activeIndex: 0, fraction: 0.6),
                              (urls: [urls[2]], activeIndex: 0, fraction: 0.4)],
                             activeGroupIndex: 1)
        settle()
        XCTAssertEqual(groupNames, [["a.md", "b.md"], ["c.md"]])
        XCTAssertEqual(editor.groupActiveTabIndicesForTesting, [0, 2])
        XCTAssertEqual(editor.focusedGroupIndexForTesting, 1)
        XCTAssertEqual(editor.groupFractionsForTesting[0], 0.6, accuracy: 0.001)
        XCTAssertEqual(editor.paneGroupIndexForTesting(tabAt: 0), 0)
        XCTAssertEqual(editor.paneGroupIndexForTesting(tabAt: 2), 1)
        XCTAssertNil(editor.paneGroupIndexForTesting(tabAt: 1), "a background tab stays dormant")
    }
}
