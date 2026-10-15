import XCTest
import ChalkKit
@testable import ChalkMac

/// A click that the pointer reads as a micro-drag must still switch tabs.
///
/// A name lifts into a reorder once the pointer moves past the threshold; a
/// lift that ends in the slot it started from is a click, recovered at the
/// END of the session (`endReorder`). The AppKit strip of the Catalyst shell
/// applied the same rule on mouse-up (2026-07-23).
///
/// The strip's press and reorder seams are driven directly: AppKit vends no
/// constructible mouse events, and the rule is about the session, not the
/// event stream.
@MainActor
final class TabClickJitterTests: XCTestCase {
    private var window: NSWindow!
    private var strip: HeaderTabStrip!
    private var selected: [UUID] = []
    private var moved: [(UUID, Int)] = []

    override func setUp() {
        super.setUp()
        window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 800, height: 46))
        strip = HeaderTabStrip(frame: CGRect(x: 0, y: 0, width: 800, height: 46))
        strip.onSelect = { [weak self] id in self?.selected.append(id) }
        strip.onMove = { [weak self] id, index in self?.moved.append((id, index)) }
        window.addSubview(strip)
        window.isHidden = false
    }

    override func tearDown() {
        strip.removeFromSuperview()
        window.isHidden = true
        window = nil
        strip = nil
        selected = []
        moved = []
        super.tearDown()
    }

    private func item(_ name: String, active: Bool = false) -> TabItem {
        TabItem(id: UUID(), name: name, isDirty: false, isActive: active, isPreview: false)
    }

    private func laidOutStrip(_ items: [TabItem]) {
        strip.update(items)
        window.layoutIfNeeded()
        strip.layoutIfNeeded()
    }

    /// The parked-update replay is deferred one turn (see `tabPressDidEnd`).
    private func waitForMainQueue() {
        let exp = expectation(description: "main queue drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    func testDragEndingWhereItStartedSelectsTheTab() {
        let a = item("a", active: true), b = item("b"), c = item("c")
        laidOutStrip([a, b, c])

        strip.tabPressDidBegin(b.id)
        strip.beginReorder(b.id)
        strip.tabPressDidEnd()
        strip.endReorder()

        XCTAssertEqual(selected, [b.id], "a lift that never reordered is a click")
        XCTAssertTrue(moved.isEmpty, "and it must not commit a reorder")
    }

    func testDragThatReordersDoesNotSelectTheTab() {
        let a = item("a", active: true), b = item("b"), c = item("c")
        laidOutStrip([a, b, c])

        strip.tabPressDidBegin(b.id)
        strip.beginReorder(b.id)
        // Pull b past the trailing edge: the walk lands it after c.
        strip.reorderMoved(toX: strip.bounds.maxX - 1)
        strip.tabPressDidEnd()
        strip.endReorder()

        XCTAssertEqual(moved.map(\.0), [b.id], "a real pull commits the move")
        XCTAssertEqual(moved.map(\.1), [2])
        XCTAssertTrue(selected.isEmpty, "a reorder is not a click")
    }

    /// The other lost-click lane: `rebuild` drops every name and builds new
    /// ones, so an `update(_:)` landing between mouse-down and mouse-up takes
    /// the pressed name, and its pending click, with it. Parking during a
    /// press is the same trick the strip already uses mid-drag.
    func testUpdateDuringAPressDoesNotRebuildTheChips() {
        let a = item("a", active: true), b = item("b")
        laidOutStrip([a, b])

        strip.tabPressDidBegin(b.id)
        strip.update([a, b, item("c")]) // e.g. a save confirming mid-press

        XCTAssertEqual(strip.renderedTabIDsForTesting, [a.id, b.id],
                       "the pressed chip must survive until the tap lands")
    }

    func testParkedUpdateAppliesAfterThePressEnds() {
        let a = item("a", active: true), b = item("b"), c = item("c")
        laidOutStrip([a, b])

        strip.tabPressDidBegin(b.id)
        strip.update([a, b, c])
        strip.tabPressDidEnd()
        waitForMainQueue()

        XCTAssertEqual(strip.renderedTabIDsForTesting, [a.id, b.id, c.id])
    }

    func testParkedReplayRebuildsFromTheNEWESTModel() {
        let a = item("a", active: true), b = item("b"), c = item("c"), d = item("d")
        laidOutStrip([a, b])

        strip.tabPressDidBegin(b.id)
        strip.update([a, b, c])
        strip.update([a, b, c, d]) // a second update inside the same press
        strip.tabPressDidEnd()
        waitForMainQueue()

        XCTAssertEqual(strip.renderedTabIDsForTesting, [a.id, b.id, c.id, d.id])
    }
}
