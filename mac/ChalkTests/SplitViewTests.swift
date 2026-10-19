import XCTest
import ChalkKit
@testable import Chalk

/// The split editor (⌘\): two tabs of the one strip side by side. `activeTab` is the focused
/// pane's, the other pane holds `splitTab`, and focus moves without reinstalling either surface.
@MainActor
final class SplitViewTests: XCTestCase {
    private var window: NSWindow!
    private var editor: EditorContainerViewController!
    private var tempDir: URL!
    private var incomingFractionRaw: Any?

    override func setUp() {
        super.setUp()
        incomingFractionRaw = UserDefaults.standard.object(forKey: Preferences.splitFractionKey)
        UserDefaults.standard.removeObject(forKey: Preferences.splitFractionKey)
        window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1200, height: 700))
        window.isHidden = false
        editor = EditorContainerViewController()
        editor.motionIsInstantForTesting = true
        window.rootViewController = editor
        editor.loadViewIfNeeded()
        window.layoutIfNeeded()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-split-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let raw = incomingFractionRaw {
            UserDefaults.standard.set(raw, forKey: Preferences.splitFractionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Preferences.splitFractionKey)
        }
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

    // MARK: Opening and closing

    func testToggleShowsThePreviousTabBesideTheActiveOne() throws {
        try open("a.md")
        try open("b.md")
        editor.toggleSplit()
        settle()
        XCTAssertTrue(editor.isSplit)
        XCTAssertEqual(editor.activeTabIndexForTesting, 1, "focus stays on the tab you were in")
        XCTAssertEqual(editor.splitTabIndexForTesting, 0, "the new pane shows the tab you came from")
        XCTAssertEqual(editor.paneSideForTesting(tabAt: 1), "leading")
        XCTAssertEqual(editor.paneSideForTesting(tabAt: 0), "trailing")
        let panes = editor.paneFramesForTesting
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes[0].width, panes[1].width, accuracy: 1, "a fresh split is halves")

        editor.toggleSplit()
        settle()
        XCTAssertFalse(editor.isSplit)
        XCTAssertEqual(editor.activeTabIndexForTesting, 1)
        XCTAssertNil(editor.paneSideForTesting(tabAt: 0), "the other pane's surface is detached")
        XCTAssertEqual(editor.paneFramesForTesting.count, 1)
    }

    func testASplitNeedsTwoTabs() throws {
        try open("a.md")
        XCTAssertFalse(editor.canToggleSplit)
        editor.toggleSplit()
        XCTAssertFalse(editor.isSplit)
    }

    func testTheStripMarksTheOtherPanesTab() throws {
        try open("a.md")
        try open("b.md")
        editor.toggleSplit()
        let items = editor.tabItemsForTesting
        XCTAssertEqual(items.map(\.isActive), [false, true])
        XCTAssertEqual(items.map(\.isShownInSplit), [true, false])
    }

    // MARK: Focus

    func testAChipClickLoadsTheFocusedPane() throws {
        try open("a.md")
        try open("b.md")
        try open("c.md")
        editor.toggleSplit() // c | b
        settle()
        editor.activate(id: id(ofTabAt: 0))
        settle()
        XCTAssertEqual(editor.activeTabIndexForTesting, 0)
        XCTAssertEqual(editor.splitTabIndexForTesting, 1, "the other pane keeps its tab")
        XCTAssertEqual(editor.paneSideForTesting(tabAt: 0), "leading")
        XCTAssertEqual(editor.paneSideForTesting(tabAt: 1), "trailing")
        XCTAssertNil(editor.paneSideForTesting(tabAt: 2), "the replaced tab leaves the pane")
    }

    func testOpeningTheOtherPanesFileMovesFocusWithoutADuplicate() throws {
        try open("a.md")
        let b = try open("b.md")
        try open("c.md")
        editor.activate(id: id(ofTabAt: 0)) // focus a; b is the previous tab
        editor.activate(id: id(ofTabAt: 1))
        editor.activate(id: id(ofTabAt: 0))
        editor.toggleSplit() // a | b
        settle()
        XCTAssertEqual(editor.splitTabIndexForTesting, 1)
        editor.open(url: b)
        settle()
        XCTAssertEqual(editor.tabCountForTesting, 3, "no second tab for the same file")
        XCTAssertEqual(editor.activeTabIndexForTesting, 1)
        XCTAssertEqual(editor.splitTabIndexForTesting, 0)
        XCTAssertEqual(editor.paneSideForTesting(tabAt: 1), "trailing", "focus moves; surfaces stay")
        XCTAssertEqual(editor.paneSideForTesting(tabAt: 0), "leading")
    }

    func testAClickInTheOtherPaneFocusesIt() throws {
        try open("a.md")
        try open("b.md")
        editor.toggleSplit() // b | a
        editor.focusPaneForTesting(tabAt: 0)
        XCTAssertEqual(editor.activeTabIndexForTesting, 0)
        XCTAssertEqual(editor.splitTabIndexForTesting, 1)
        XCTAssertEqual(editor.tabItemsForTesting.map(\.isActive), [true, false])
    }

    func testOpenInSplitShowsTheTabBesideAndFocusesIt() throws {
        try open("a.md")
        try open("b.md")
        try open("c.md")
        editor.openInSplit(id: id(ofTabAt: 0))
        settle()
        XCTAssertTrue(editor.isSplit)
        XCTAssertEqual(editor.activeTabIndexForTesting, 0)
        XCTAssertEqual(editor.splitTabIndexForTesting, 2)
        XCTAssertEqual(editor.paneSideForTesting(tabAt: 0), "trailing")
        XCTAssertEqual(editor.paneSideForTesting(tabAt: 2), "leading")
    }

    func testCyclingTabsSkipsTheOtherPane() throws {
        try open("a.md")
        try open("b.md")
        try open("c.md")
        editor.toggleSplit() // c | b
        editor.nextTab()
        XCTAssertEqual(editor.activeTabIndexForTesting, 0, "c wraps to a, past b in the other pane")
        XCTAssertEqual(editor.splitTabIndexForTesting, 1)
    }

    // MARK: Closing tabs

    func testClosingTheOtherPanesTabRefillsIt() throws {
        try open("a.md")
        try open("b.md")
        try open("c.md")
        editor.toggleSplit() // c | b
        editor.closeTab(id: id(ofTabAt: 1))
        settle()
        XCTAssertTrue(editor.isSplit)
        XCTAssertEqual(editor.activeTabIndexForTesting, 1, "c, now at index 1")
        XCTAssertEqual(editor.splitTabIndexForTesting, 0, "a fills the pane b left")
        XCTAssertEqual(editor.paneSideForTesting(tabAt: 0), "trailing")
    }

    func testClosingTheOtherPanesLastCandidateClosesTheSplit() throws {
        try open("a.md")
        try open("b.md")
        editor.toggleSplit() // b | a
        editor.closeTab(id: id(ofTabAt: 0))
        settle()
        XCTAssertFalse(editor.isSplit)
        XCTAssertEqual(editor.activeTabIndexForTesting, 0)
        XCTAssertEqual(editor.paneFramesForTesting.count, 1)
    }

    func testClosingTheFocusedTabLeavesTheOtherPaneInPlace() throws {
        try open("a.md")
        try open("b.md")
        editor.toggleSplit() // b | a
        editor.closeActiveTab()
        settle()
        XCTAssertFalse(editor.isSplit)
        XCTAssertEqual(editor.activeTabIndexForTesting, 0)
        XCTAssertEqual(editor.paneSideForTesting(tabAt: 0), "trailing",
                       "the survivor keeps its pane, which now fills the area")
        let frames = editor.paneFramesForTesting
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], editor.contentViewFrameForTesting)
    }

    // MARK: The trailing slot follows focus

    func testTheOutlineFollowsTheFocusedPane() throws {
        try open("a.md")
        try open("b.md")
        editor.showTrailingPanel(.outline, animated: false)
        editor.toggleSplit() // b | a
        XCTAssertEqual(editor.outlineSubscriptionForTesting(tabAt: 1), true)
        XCTAssertEqual(editor.outlineSubscriptionForTesting(tabAt: 0), false)
        editor.focusOtherPane()
        XCTAssertEqual(editor.outlineSubscriptionForTesting(tabAt: 0), true)
        XCTAssertEqual(editor.outlineSubscriptionForTesting(tabAt: 1), false)
    }

    func testThePDFFollowsTheFocusedPanesTab() throws {
        try open("a.tex")
        try open("b.md")
        editor.toggleSplit() // b | a
        editor.focusOtherPane() // a
        editor.showTrailingPanel(.pdf, animated: false)
        XCTAssertTrue(editor.isPDFPanelShowing)
        editor.focusOtherPane() // b has no PDF, and no outline is wanted
        XCTAssertFalse(editor.isPDFPanelShowing)
        editor.focusOtherPane()
        XCTAssertTrue(editor.isPDFPanelShowing, "a's PDF comes back with focus")
    }

    // MARK: The seam

    func testTheDividerPersistsItsShareAndKeepsThePaneFloor() throws {
        try open("a.md")
        try open("b.md")
        editor.toggleSplit()
        settle()
        let column = editor.contentViewFrameForTesting.width
        editor.dragSplitDividerForTesting(by: 100)
        XCTAssertEqual(editor.paneFramesForTesting[0].width, column / 2 + 100, accuracy: 1)
        XCTAssertEqual(Preferences.splitFraction, (column / 2 + 100) / column, accuracy: 0.01)

        editor.dragSplitDividerForTesting(by: -column)
        XCTAssertGreaterThanOrEqual(editor.paneFramesForTesting[0].width,
                                    ChalkMetrics.splitMinimumPaneWidth - 0.5)
    }

    // MARK: Session

    func testTheSessionNamesTheOtherPaneAndItsSide() throws {
        try open("a.md")
        try open("b.md")
        editor.toggleSplit() // b | a
        var snapshot = editor.sessionSnapshot()
        XCTAssertEqual(snapshot.activeIndex, 1)
        XCTAssertEqual(snapshot.splitIndex, 0)
        XCTAssertFalse(snapshot.splitIsLeading)
        editor.focusOtherPane()
        snapshot = editor.sessionSnapshot()
        XCTAssertEqual(snapshot.activeIndex, 0)
        XCTAssertEqual(snapshot.splitIndex, 1)
        XCTAssertTrue(snapshot.splitIsLeading, "b, unfocused, sits on the leading side")
    }

    func testRestoreSplitPutsTheTabOnItsSide() throws {
        try open("a.md")
        try open("b.md")
        editor.restoreSplit(fileTabAt: 0, leading: true)
        settle()
        XCTAssertTrue(editor.isSplit)
        XCTAssertEqual(editor.paneSideForTesting(tabAt: 0), "leading")
        XCTAssertEqual(editor.paneSideForTesting(tabAt: 1), "trailing")
        XCTAssertEqual(editor.activeTabIndexForTesting, 1)
    }
}
