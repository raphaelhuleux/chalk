import XCTest
import ChalkKit
@testable import Chalk

/// Middle-click closes a tab (browser convention, 2026-08-18). On Mac the
/// windowed strip is AppKit and handles the button itself; in FULL SCREEN the
/// UIKit band is the strip, and Catalyst routes the middle button through the
/// AppKit event stream only — the glue's monitor forwards the point and
/// `replayMiddleClick` turns it back into the close it would have been. The
/// AppKit half can only be checked in the running Mac app; this half is plain
/// hit-testing.
final class TabMiddleClickTests: XCTestCase {
    private var window: NSWindow!
    private var strip: HeaderTabStrip!
    private var closed: [UUID] = []
    private var selected: [UUID] = []

    override func setUp() {
        super.setUp()
        window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 800, height: 46))
        strip = HeaderTabStrip(frame: CGRect(x: 0, y: 0, width: 800, height: 46))
        strip.onClose = { [weak self] id in self?.closed.append(id) }
        strip.onSelect = { [weak self] id in self?.selected.append(id) }
        window.addSubview(strip)
        window.isHidden = false
    }

    override func tearDown() {
        strip.removeFromSuperview()
        window.isHidden = true
        window = nil
        strip = nil
        closed = []
        selected = []
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

    func testMiddleClickOnAChipClosesThatTab() {
        let a = item("a", active: true), b = item("b"), c = item("c")
        laidOutStrip([a, b, c])

        let frame = strip.tabFrameInWindowForTesting(b.id)!
        strip.replayMiddleClick(atWindowPoint: CGPoint(x: frame.midX, y: frame.midY))

        XCTAssertEqual(closed, [b.id], "the middle-clicked tab should close")
        XCTAssertEqual(selected, [], "and it must not be selected on the way out")
    }

    func testMiddleClickOnTheActiveChipClosesItToo() {
        let a = item("a", active: true), b = item("b")
        laidOutStrip([a, b])

        let frame = strip.tabFrameInWindowForTesting(a.id)!
        strip.replayMiddleClick(atWindowPoint: CGPoint(x: frame.midX, y: frame.midY))

        XCTAssertEqual(closed, [a.id])
    }

    func testMiddleClickBesideTheChipsClosesNothing() {
        let a = item("a", active: true), b = item("b")
        laidOutStrip([a, b])

        let last = strip.tabFrameInWindowForTesting(b.id)!
        // Past the trailing edge of the last chip: the "+" chip and empty band.
        strip.replayMiddleClick(atWindowPoint: CGPoint(x: last.maxX + 30, y: last.midY))
        // Above the band entirely (a click in the window's chrome).
        strip.replayMiddleClick(atWindowPoint: CGPoint(x: last.midX, y: -20))

        XCTAssertEqual(closed, [], "only a hit on a chip closes anything")
    }
}
