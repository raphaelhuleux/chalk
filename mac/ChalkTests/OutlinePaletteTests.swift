import XCTest
import ChalkKit
@testable import Chalk

/// Behavior of the outline palette VC with a canned snapshot: list contents,
/// preselection, activation, empty state, and the height report. All through
/// the VC's public API plus DEBUG `…ForTesting` accessors; no webview involved.
@MainActor
final class OutlinePaletteTests: XCTestCase {
    private func makeVC() -> OutlinePaletteViewController {
        let vc = OutlinePaletteViewController()
        vc.loadViewIfNeeded()
        return vc
    }

    private var sampleSnapshot: OutlineSnapshot {
        OutlineSnapshot(
            items: [
                OutlineItem(kind: .heading, level: 1, title: "Intro", line: 1,
                            calloutType: nil, number: nil),
                OutlineItem(kind: .callout, level: 0, title: "Pythagoras", line: 4,
                            calloutType: "theorem", number: 1),
                OutlineItem(kind: .heading, level: 2, title: "Results", line: 9,
                            calloutType: nil, number: nil),
                OutlineItem(kind: .figure, level: 0, title: "convergence", line: 12,
                            calloutType: nil, number: 1),
            ],
            cursorLine: 10)
    }

    func testSnapshotPopulatesRowsAndPreselectsCursorSection() {
        let vc = makeVC()
        vc.setSnapshot(sampleSnapshot)
        XCTAssertEqual(vc.visibleItemsForTesting.map(\.line), [1, 4, 9, 12])
        // Cursor on line 10 sits in "Results" (line 9): index 2.
        XCTAssertEqual(vc.selectedIndexForTesting, 2)
    }

    func testConfirmFiresJumpWithSelectedLineThroughCloseDiscipline() {
        let vc = makeVC()
        var jumped: [Int] = []
        var closed = 0
        vc.onJump = { jumped.append($0) }
        vc.onClose = { then in
            closed += 1
            then?()
        }
        vc.setSnapshot(sampleSnapshot)
        vc.confirmSelectedForTesting()
        XCTAssertEqual(jumped, [9])
        XCTAssertEqual(closed, 1)
    }

    func testFilterNarrowsRowsAndResetsSelection() {
        let vc = makeVC()
        vc.setSnapshot(sampleSnapshot)
        vc.setQueryForAudit("figure")
        XCTAssertEqual(vc.visibleItemsForTesting.map(\.line), [12])
        XCTAssertEqual(vc.selectedIndexForTesting, 0)
    }

    func testEmptySnapshotShowsEmptyState() {
        let vc = makeVC()
        vc.setSnapshot(.empty)
        XCTAssertTrue(vc.isEmptyStateVisibleForTesting)
        vc.setSnapshot(sampleSnapshot)
        XCTAssertFalse(vc.isEmptyStateVisibleForTesting)
    }

    func testHeightReportCapsAtTenRows() {
        let vc = makeVC()
        var heights: [CGFloat] = []
        vc.onContentHeightChanged = { heights.append($0) }

        let many = (1...30).map {
            OutlineItem(kind: .heading, level: 1, title: "H\($0)", line: $0,
                        calloutType: nil, number: nil)
        }
        vc.setSnapshot(OutlineSnapshot(items: many, cursorLine: 1))
        let tall = heights.last ?? 0

        vc.setSnapshot(OutlineSnapshot(items: Array(many.prefix(10)), cursorLine: 1))
        let tenRows = heights.last ?? 0

        XCTAssertEqual(tall, tenRows, "30 rows must report the same height as 10")
    }

    func testPrepareForReuseClearsQueryAndItems() {
        let vc = makeVC()
        vc.setSnapshot(sampleSnapshot)
        vc.setQueryForAudit("theo")
        vc.prepareForReuse()
        XCTAssertEqual(vc.visibleItemsForTesting.count, 0)
        XCTAssertTrue(vc.isEmptyStateVisibleForTesting)
    }

    /// The field's commands: arrows move the row, Escape cancels, Return
    /// jumps, through the same path the field editor takes.
    func testFieldCommandsDriveTheSelection() {
        let vc = makeVC()
        var jumped: [Int] = []
        var closed = 0
        vc.onJump = { jumped.append($0) }
        vc.onClose = { then in closed += 1; then?() }
        vc.setSnapshot(sampleSnapshot)
        let field = vc.searchFieldForTesting
        let editor = NSTextView()
        XCTAssertTrue(vc.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(vc.selectedIndexForTesting, 3)
        XCTAssertTrue(vc.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertTrue(vc.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(vc.selectedIndexForTesting, 1)
        XCTAssertTrue(vc.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(jumped, [4])
        XCTAssertTrue(vc.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(closed, 2)
        XCTAssertFalse(vc.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))),
                       "anything else is the field's own")
    }

    /// With no window the focus grab always fails, so didReveal keeps the
    /// spaced retry chain alive, the precondition the cancellation test below
    /// relies on (guards it against passing vacuously).
    func testFocusRetriesContinueWhileRevealed() {
        let vc = makeVC()
        vc.didReveal()
        XCTAssertEqual(vc.focusAttemptCountForTesting, 1)
        // Outlast the whole chain: 5 retries spaced 60ms (plus slack).
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
        XCTAssertEqual(vc.focusAttemptCountForTesting, 6, "initial attempt + 5 retries")
    }

    /// willHide (called by the host on every dismiss path) must cancel retries
    /// still pending, or a late retry hands the keyboard to the hidden search
    /// field and steals it from the editor.
    func testWillHideCancelsPendingFocusRetries() {
        let vc = makeVC()
        vc.didReveal()
        XCTAssertEqual(vc.focusAttemptCountForTesting, 1)
        vc.willHide()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
        XCTAssertEqual(vc.focusAttemptCountForTesting, 1,
                       "no retry may fire after dismissal")
    }
}
