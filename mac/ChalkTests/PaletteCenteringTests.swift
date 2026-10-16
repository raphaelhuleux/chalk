import XCTest
import ChalkKit
@testable import Chalk

/// Both palettes float centered in the window on BOTH axes (the iA Writer
/// Quick Search placement: its card's center sits on the window's center, not
/// on a fixed offset from the title bar).
///
/// Frame-hosted without a window: "the available area" IS the whole root.
@MainActor
final class PaletteCenteringTests: XCTestCase {
    private func makeRoot(size: CGSize = CGSize(width: 1180, height: 820))
        -> RootSplitViewController {
        let root = RootSplitViewController()
        root.loadViewIfNeeded()
        root.view.frame = CGRect(origin: .zero, size: size)
        root.view.layoutSubtreeIfNeeded()
        return root
    }

    private func assertCentered(
        _ card: CGRect, in root: RootSplitViewController,
        _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(card.isNull, "\(label): no card mounted", file: file, line: line)
        XCTAssertEqual(card.midX, root.view.bounds.midX, accuracy: 0.5,
                       "\(label) is horizontally centered in the window",
                       file: file, line: line)
        XCTAssertEqual(card.midY, root.view.bounds.midY, accuracy: 0.5,
                       "\(label) is vertically centered in the window",
                       file: file, line: line)
    }

    func testQuickOpenCardIsCenteredInTheWindow() {
        let root = makeRoot()
        root.cmdQuickOpen()
        root.view.layoutSubtreeIfNeeded()
        assertCentered(root.quickOpenCardFrameForTesting, in: root, "Quick Open")
    }

    func testOutlinePaletteCardIsCenteredInTheWindow() {
        let root = makeRoot()
        root.cmdToggleOutline()
        root.view.layoutSubtreeIfNeeded()
        assertCentered(root.outlineCardFrameForTesting, in: root, "outline palette")
    }

    /// Centering is an EQUALITY, so a window too short for the whole result
    /// set must resolve by shrinking the card (the height is `.defaultHigh`
    /// for exactly this) and never by breaking a constraint and letting the
    /// card bleed off-window.
    func testShortWindowShrinksTheCardInsteadOfOverflowing() {
        let root = makeRoot(size: CGSize(width: 900, height: 380))
        root.cmdQuickOpen()
        root.view.layoutSubtreeIfNeeded()
        let card = root.quickOpenCardFrameForTesting
        XCTAssertTrue(root.view.bounds.insetBy(dx: 0, dy: 39).contains(card),
                      "card \(card) stays inside the window with its margins")
        assertCentered(card, in: root, "Quick Open in a short window")
    }

    /// Centering must track the window, not a constant: a tall window puts the
    /// card lower, a short one higher.
    func testCenteringTracksWindowHeight() {
        let root = makeRoot(size: CGSize(width: 900, height: 1200))
        root.cmdQuickOpen()
        root.view.layoutSubtreeIfNeeded()
        assertCentered(root.quickOpenCardFrameForTesting, in: root, "Quick Open in a tall window")
    }

    /// The card is the spec width and hugs its results.
    func testTheCardTakesTheSpecWidth() {
        let root = makeRoot()
        root.cmdQuickOpen()
        root.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(root.quickOpenCardFrameForTesting.width, ChalkMetrics.paletteWidth, accuracy: 0.5)
    }
}
