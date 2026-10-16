import XCTest
import ChalkKit
@testable import Chalk

@MainActor
final class OutlinePanelViewControllerTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { dismantleHostedSidebar(window) }
        windows = []
        super.tearDown()
    }

    private func heading(_ title: String, level: Int = 1, line: Int) -> OutlineItem {
        OutlineItem(kind: .heading, level: level, title: title, line: line, calloutType: nil, number: nil)
    }

    private func hosted(_ existing: OutlinePanelViewController? = nil)
        -> (NSWindow, OutlinePanelViewController) {
        let vc = existing ?? OutlinePanelViewController()
        let window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        window.rootViewController = vc
        window.isHidden = false
        vc.view.layoutSubtreeIfNeeded()
        windows.append(window)
        return (window, vc)
    }

    private var three: [OutlineItem] { [heading("A", line: 1), heading("B", line: 10), heading("C", line: 20)] }

    /// The document-header artboard's sample: a level-1 title, level-2
    /// sections, level-3 subsections.
    private var tree: [OutlineItem] {
        [heading("Outline demo", level: 1, line: 1),
         heading("Setup", level: 2, line: 5),
         heading("Requirements", level: 3, line: 9),
         heading("Method", level: 2, line: 13)]
    }

    // MARK: - Stats footer

    func testFooterShowsWordsAndCharacters() {
        let (_, vc) = hosted()
        vc.setSnapshot(OutlineSnapshot(items: three, cursorLine: 1,
                                       stats: DocumentStats(words: 12, characters: 40)))
        XCTAssertEqual(vc.statsTextForTesting, "12 words\n40 characters")
    }

    func testFooterCountsTheSelectionAgainstTheTotal() {
        let (_, vc) = hosted()
        vc.setSnapshot(OutlineSnapshot(items: three, cursorLine: 1,
                                       stats: DocumentStats(words: 12, characters: 40, selectionWords: 3)))
        XCTAssertEqual(vc.statsTextForTesting, "3 of 12 words\n40 characters")
    }

    func testFooterSingularAndHiddenWithoutStats() {
        let (_, vc) = hosted()
        vc.setSnapshot(OutlineSnapshot(items: [], cursorLine: 1,
                                       stats: DocumentStats(words: 1, characters: 1)))
        XCTAssertEqual(vc.statsTextForTesting, "1 word\n1 character")
        vc.setSnapshot(OutlineSnapshot(items: [], cursorLine: 1))
        XCTAssertNil(vc.statsTextForTesting, "no document, no footer")
    }

    func testSnapshotSelectsTheCaretsSection() {
        let (_, vc) = hosted()
        vc.setSnapshot(OutlineSnapshot(items: three, cursorLine: 12))
        XCTAssertEqual(vc.selectedRowForTesting, 1)
    }

    func testCaretMoveAloneMovesTheSelectionWithoutReloading() {
        let (_, vc) = hosted()
        vc.setSnapshot(OutlineSnapshot(items: three, cursorLine: 12))
        let reloads = vc.reloadCountForTesting
        vc.setSnapshot(OutlineSnapshot(items: three, cursorLine: 25))
        XCTAssertEqual(vc.reloadCountForTesting, reloads)
        XCTAssertEqual(vc.selectedRowForTesting, 2)
    }

    func testChangedItemsReload() {
        let (_, vc) = hosted()
        vc.setSnapshot(OutlineSnapshot(items: three, cursorLine: 1))
        let reloads = vc.reloadCountForTesting
        vc.setSnapshot(OutlineSnapshot(items: three + [heading("D", line: 30)], cursorLine: 1))
        XCTAssertEqual(vc.reloadCountForTesting, reloads + 1)
    }

    func testClickJumpsToTheRowsLine() {
        let (_, vc) = hosted()
        vc.setSnapshot(OutlineSnapshot(items: three, cursorLine: 1))
        var jumped: [Int] = []
        vc.onJump = { jumped.append($0) }
        vc.jumpToRowForTesting(2)
        XCTAssertEqual(jumped, [20])
    }

    func testEmptySnapshotShowsTheEmptyState() {
        let (_, vc) = hosted()
        vc.setSnapshot(.empty)
        XCTAssertTrue(vc.isEmptyStateVisibleForTesting)
        vc.setSnapshot(OutlineSnapshot(items: three, cursorLine: 1))
        XCTAssertFalse(vc.isEmptyStateVisibleForTesting)
    }

    /// The panel is chrome, like the Library: it paints the chrome tone, not
    /// the editor's paper, so the two side columns read as one system.
    func testPanelPaintsTheChromeBackground() {
        let (_, vc) = hosted()
        XCTAssertTrue(vc.view is ChromeToneView)
    }

    /// The header names the document the outline belongs to, and survives
    /// being set before the view loads.
    func testHeaderShowsTheDocumentName() {
        let vc = OutlinePanelViewController()
        vc.setDocumentName("outline-demo.md")
        let (_, hostedVC) = hosted(vc)
        XCTAssertEqual(hostedVC.headerDocumentNameForTesting, "outline-demo.md")
        hostedVC.setDocumentName("notes.tex")
        XCTAssertEqual(hostedVC.headerDocumentNameForTesting, "notes.tex")
    }

    /// The header sits up in the band at a fixed distance from the panel's
    /// top (the design puts it level with the traffic lights, not below them).
    func testHeaderSitsNearTheTop() {
        let (window, vc) = hosted()
        vc.setSnapshot(OutlineSnapshot(items: three, cursorLine: 1))
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(vc.headerFrameForTesting.minY, OutlinePanelViewController.headerTop, accuracy: 0.5)
    }

    /// Nesting shows as tree guides: one hairline per ancestor level, so a
    /// level-3 heading carries two, a level-2 one, the title none.
    func testRowsCarryOneGuidePerAncestorLevel() {
        let (_, vc) = hosted()
        vc.setSnapshot(OutlineSnapshot(items: tree, cursorLine: 1))
        vc.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(vc.guideCountForTesting(row: 0), 0)
        XCTAssertEqual(vc.guideCountForTesting(row: 1), 1)
        XCTAssertEqual(vc.guideCountForTesting(row: 2), 2)
        XCTAssertEqual(vc.guideCountForTesting(row: 3), 1)
    }

    /// Rows are the design's 32pt, denser than the palette's 36.
    func testRowsAreThirtyTwoPointsTall() {
        let (_, vc) = hosted()
        vc.setSnapshot(OutlineSnapshot(items: three, cursorLine: 1))
        XCTAssertEqual(vc.tableViewForTesting.rowHeight, 32, accuracy: 0.5)
    }
}
