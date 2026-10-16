import XCTest
import ChalkKit
@testable import Chalk

/// A palette dims the window behind it, and the tab strip is part of that
/// window. On Catalyst the windowed strip lived in a layer no scrim could
/// reach and had to be told; here the band is the root's own view, so the
/// scrim covers it like everything else. This pins that it does.
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
        let state = UIState(window: .windowed, sidebar: .hidden, mode: .normal, appearance: .light)
        let root = host.makeRoot(for: state)
        host.settleToFixedPoint(root, state: state)
        return root
    }

    private func pump(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func testQuickOpenScrimsTheStripWhileItIsUp() {
        let root = settledRoot()
        XCTAssertFalse(root.isScrimCoveringTheBandForTesting, "precondition: nothing dimmed at rest")

        root.cmdQuickOpen()
        pump()
        XCTAssertTrue(root.isQuickOpenVisibleForTesting, "precondition: the palette opened")
        XCTAssertTrue(root.isScrimCoveringTheBandForTesting,
                      "the tab strip must dim with the editor behind a palette")

        root.cmdQuickOpen() // toggles closed
        pump()
        XCTAssertFalse(root.isQuickOpenVisibleForTesting, "precondition: the palette closed")
        XCTAssertFalse(root.isScrimCoveringTheBandForTesting,
                       "and must come back when the palette goes")
    }

    func testOutlinePaletteScrimsTheStripToo() {
        let root = settledRoot()
        root.cmdToggleOutline()
        pump()
        XCTAssertTrue(root.isOutlineVisibleForTesting, "precondition: the outline opened")
        XCTAssertTrue(root.isScrimCoveringTheBandForTesting,
                      "both palettes dim the window; the strip is part of it")

        root.cmdToggleOutline()
        pump()
        XCTAssertFalse(root.isScrimCoveringTheBandForTesting)
    }
}
