import XCTest
import ChalkKit
@testable import Chalk

/// A palette dims the window behind it, and the tab strip is part of that
/// window.
///
/// The scrim is a UIKit view pinned over the split view, so in full screen it
/// covers the tab band (measured: scrim at subview index 5, header at 2).
/// Windowed, the tab row is not a UIKit view at all — it lives in the
/// titlebar as AppKit, in a layer no UIKit scrim can reach — so the editor
/// dimmed while the tabs stayed lit, and in light mode that reads as the
/// editor having gone the wrong colour.
///
/// The strip therefore has to be told. This pins the DECISION; the AppKit
/// drawing it drives lives in a bundle no test links.
@MainActor
final class PaletteStripScrimTests: XCTestCase {
    private var host: ChromeMatrixHost!

    override func setUp() {
        super.setUp()
        host = ChromeMatrixHost()
    }

    override func tearDown() {
        host.restoreAndDismantle()
        host = nil
        super.tearDown()
    }

    private func settledRoot() -> RootSplitViewController {
        let state = UIState(window: .windowed,
                            sidebar: .hidden, mode: .normal, appearance: .light)
        let root = host.makeRoot(for: state)
        host.settleToFixedPoint(root, state: state)
        return root
    }

    private func pump(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func testQuickOpenScrimsTheStripWhileItIsUp() {
        let root = settledRoot()
        XCTAssertFalse(root.lastStripScrimmedForTesting, "precondition: nothing dimmed at rest")

        root.cmdQuickOpen()
        pump()
        XCTAssertTrue(root.isQuickOpenVisibleForTesting, "precondition: the palette opened")
        XCTAssertTrue(root.lastStripScrimmedForTesting,
                      "the tab strip must dim with the editor behind a palette")

        root.cmdQuickOpen() // toggles closed
        pump()
        XCTAssertFalse(root.isQuickOpenVisibleForTesting, "precondition: the palette closed")
        XCTAssertFalse(root.lastStripScrimmedForTesting,
                       "and must come back when the palette goes")
    }

    func testOutlinePaletteScrimsTheStripToo() {
        let root = settledRoot()
        root.cmdToggleOutline()
        pump()
        XCTAssertTrue(root.isOutlineVisibleForTesting, "precondition: the outline opened")
        XCTAssertTrue(root.lastStripScrimmedForTesting,
                      "both palettes dim the window; the strip is part of it")

        root.cmdToggleOutline()
        pump()
        XCTAssertFalse(root.lastStripScrimmedForTesting)
    }
}
