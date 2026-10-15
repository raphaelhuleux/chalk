import XCTest
import ChalkKit
@testable import ChalkMac

/// The ⌘O palette with a canned index: the blank query lists the first
/// fifty, a query ranks on "parent/name", Return browses in place, ⌘↩ opens a
/// new tab, and the card's height hugs the results up to eight rows.
@MainActor
final class QuickOpenPaletteTests: XCTestCase {
    private func makeVC() -> QuickOpenViewController {
        let vc = QuickOpenViewController()
        vc.loadViewIfNeeded()
        return vc
    }

    private func node(_ folder: String, _ name: String) -> FileNode {
        FileNode(url: URL(fileURLWithPath: "/tmp/lib/\(folder)/\(name)"), name: name, isDirectory: false)
    }

    private var index: [FileNode] {
        [node("notes", "ideas.md"), node("papers", "draft.tex"), node("notes", "todo.md"),
         node("papers", "intro.tex")]
    }

    func testBlankQueryListsTheIndexInOrder() {
        let vc = makeVC()
        vc.setFiles(index)
        XCTAssertEqual(vc.visibleResultsForTesting.map(\.name), ["ideas.md", "draft.tex", "todo.md", "intro.tex"])
        XCTAssertEqual(vc.selectedIndexForTesting, 0)
    }

    func testQueryMatchesOnParentAndName() {
        let vc = makeVC()
        vc.setFiles(index)
        vc.setQueryForAudit("notes ideas")
        XCTAssertEqual(vc.visibleResultsForTesting.first?.name, "ideas.md")
        vc.setQueryForAudit("intro")
        XCTAssertEqual(vc.visibleResultsForTesting.map(\.name), ["intro.tex"])
    }

    /// A query set before the index arrives applies once it does.
    func testIndexArrivingLateReappliesTheQuery() {
        let vc = makeVC()
        vc.setQueryForAudit("todo")
        XCTAssertTrue(vc.visibleResultsForTesting.isEmpty)
        vc.setFiles(index)
        XCTAssertEqual(vc.visibleResultsForTesting.map(\.name), ["todo.md"])
    }

    func testReturnBrowsesInPlaceAndCommandReturnOpensANewTab() {
        let vc = makeVC()
        var opened: [(URL, Bool)] = []
        var closed = 0
        vc.onOpen = { opened.append(($0, $1)) }
        vc.onClose = { then in closed += 1; then?() }
        vc.setFiles(index)
        vc.moveSelectionForTesting(down: true)
        vc.confirmSelectedForTesting()
        XCTAssertEqual(opened.last?.0.lastPathComponent, "draft.tex")
        XCTAssertEqual(opened.last?.1, false)
        vc.confirmSelectedForTesting(inNewTab: true)
        XCTAssertEqual(opened.last?.1, true)
        XCTAssertEqual(closed, 2, "every open goes through the host's close")
    }

    /// The field's commands reach the same paths the field editor takes.
    func testFieldCommandsDriveTheSelection() {
        let vc = makeVC()
        var opened: [URL] = []
        vc.onOpen = { url, _ in opened.append(url) }
        vc.onClose = { then in then?() }
        vc.setFiles(index)
        let field = vc.searchFieldForTesting
        let editor = NSTextView()
        XCTAssertTrue(vc.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(vc.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(vc.selectedIndexForTesting, 2)
        XCTAssertTrue(vc.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(opened.map(\.lastPathComponent), ["todo.md"])
    }

    func testHeightReportCapsAtEightRows() {
        let vc = makeVC()
        var heights: [CGFloat] = []
        vc.onContentHeightChanged = { heights.append($0) }
        let many = (1...30).map { node("f", "n\($0).md") }
        vc.setFiles(many)
        let tall = heights.last ?? 0
        vc.setFiles(Array(many.prefix(8)))
        let eight = heights.last ?? 0
        vc.setFiles(Array(many.prefix(2)))
        let two = heights.last ?? 0
        XCTAssertEqual(tall, eight, "30 rows must report the same height as 8")
        XCTAssertLessThan(two, eight, "fewer rows, a shorter card")
    }

    /// The last index survives a reuse so the palette never flashes empty;
    /// only the query resets.
    func testPrepareForReuseKeepsTheIndexAndClearsTheQuery() {
        let vc = makeVC()
        vc.setFiles(index)
        vc.setQueryForAudit("intro")
        vc.prepareForReuse()
        XCTAssertEqual(vc.visibleResultsForTesting.count, 4)
        XCTAssertEqual(vc.searchFieldForTesting.stringValue, "")
    }

    func testWillHideCancelsPendingFocusRetries() {
        let vc = makeVC()
        vc.didReveal()
        XCTAssertEqual(vc.focusAttemptCountForTesting, 1)
        vc.willHide()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertEqual(vc.focusAttemptCountForTesting, 1, "no retry may fire after dismissal")
    }

    /// Hosted, the field takes the keyboard on reveal.
    func testRevealGivesTheFieldTheKeyboard() {
        let vc = makeVC()
        let window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.rootViewController = vc
        window.isHidden = false
        defer { dismantleHostedSidebar(window) }
        vc.didReveal()
        XCTAssertNotNil(vc.searchFieldForTesting.currentEditor(), "the search field holds the keyboard")
    }
}
