import XCTest
@testable import Chalk

/// A click that the system reads as a micro-drag must still switch tabs.
///
/// The chip selects on `.touchUpInside` only, and `UIDragInteraction` lifts on
/// press + a few points of movement with NO delay for an indirect pointer
/// (the Catalyst mouse). The lift cancels the control's tracking,
/// so the tap never lands; the chip then drops back into its own slot, which
/// commits no move either. The click did nothing and the user clicks again.
///
/// The AppKit strip already treats "a drag that never left its slot" as a
/// click (ChalkTabStrip.swift, 2026-07-23); this is the UIKit half of the
/// same rule, recovered at the END of the session because UIDragInteraction
/// owns its own gesture and cannot be given a threshold up front.
final class TabClickJitterTests: XCTestCase {
    private var window: UIWindow!
    private var strip: HeaderTabStrip!
    private var selected: [UUID] = []
    private var moved: [(UUID, Int)] = []

    override func setUp() {
        super.setUp()
        window = UIWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 800, height: 46))
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

    /// The parked-update replay is deferred one turn (see `chipPressDidEnd`).
    private func waitForMainQueue() {
        let exp = expectation(description: "main queue drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    func testDragEndingWhereItStartedSelectsTheTab() {
        let a = item("a", active: true), b = item("b"), c = item("c")
        laidOutStrip([a, b, c])

        let interaction = UIDragInteraction(delegate: strip)
        let session = FakeDragSession(itemID: b.id, windowPoint: .zero)
        strip.dragInteraction(interaction, sessionWillBegin: session)
        strip.dragInteraction(interaction, session: session, didEndWith: .cancel)

        XCTAssertEqual(selected, [b.id], "a lift that never reordered is a click")
        XCTAssertTrue(moved.isEmpty, "and it must not commit a reorder")
    }

    func testDragThatReordersDoesNotSelectTheTab() {
        let a = item("a", active: true), b = item("b"), c = item("c")
        laidOutStrip([a, b, c])

        let dragInteraction = UIDragInteraction(delegate: strip)
        let dropInteraction = UIDropInteraction(delegate: strip)
        let drag = FakeDragSession(itemID: b.id, windowPoint: .zero)
        strip.dragInteraction(dragInteraction, sessionWillBegin: drag)

        // Pull b past the trailing edge: walkChip lands it after c.
        let drop = FakeDropSession(
            localDragSession: drag,
            windowPoint: CGPoint(x: strip.bounds.maxX - 1, y: strip.bounds.midY))
        _ = strip.dropInteraction(dropInteraction, sessionDidUpdate: drop)
        strip.dropInteraction(dropInteraction, performDrop: drop)
        strip.dragInteraction(dragInteraction, session: drag, didEndWith: .move)

        XCTAssertEqual(moved.map(\.0), [b.id], "a real pull commits the move")
        XCTAssertEqual(moved.map(\.1), [2])
        XCTAssertTrue(selected.isEmpty, "a reorder is not a click")
    }

    /// The other lost-click lane: `rebuild` drops every chip and builds new
    /// ones, so an `update(_:)` landing between touch-down and touch-up takes
    /// the pressed chip — and its pending `.touchUpInside` — with it. Parking
    /// during a press is the same trick the strip already uses mid-drag.
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

// MARK: - Session fakes

/// UIKit vends no constructible drag/drop session, so the strip's real
/// delegate methods are driven through these. Only what the strip reads is
/// modelled: the item's `localObject` (the tab id) and the pointer location.
private final class FakeDragSession: NSObject, UIDragSession {
    let items: [UIDragItem]
    var localContext: Any?
    let windowPoint: CGPoint

    init(itemID: UUID, windowPoint: CGPoint) {
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = itemID
        self.items = [item]
        self.windowPoint = windowPoint
    }

    func location(in view: UIView) -> CGPoint { view.convert(windowPoint, from: nil) }
    var allowsMoveOperation: Bool { true }
    var isRestrictedToDraggingApplication: Bool { true }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: NSItemProviderReading.Type) -> Bool { false }
}

private final class FakeDropSession: NSObject, UIDropSession {
    let localDragSession: UIDragSession?
    var progressIndicatorStyle: UIDropSessionProgressIndicatorStyle = .default
    let progress = Progress()
    let windowPoint: CGPoint

    init(localDragSession: UIDragSession, windowPoint: CGPoint) {
        self.localDragSession = localDragSession
        self.windowPoint = windowPoint
    }

    var items: [UIDragItem] { localDragSession?.items ?? [] }
    func location(in view: UIView) -> CGPoint { view.convert(windowPoint, from: nil) }
    var allowsMoveOperation: Bool { true }
    var isRestrictedToDraggingApplication: Bool { true }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: NSItemProviderReading.Type) -> Bool { false }
    func loadObjects(
        ofClass aClass: NSItemProviderReading.Type,
        completion: @escaping ([NSItemProviderReading]) -> Void
    ) -> Progress { Progress() }
}
