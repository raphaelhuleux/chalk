import XCTest
import ChalkKit
@testable import Chalk

/// The tab row's anatomy, as Paper draws it (2026-08-24): names on the paper,
/// an accent underline under the active one, a slot only where something rests
/// in it, and a gap between names that stays the window's to drag.
///
/// The AppKit twin (ChalkAppKitGlue) draws the same anatomy from the same
/// ChalkKit tokens (`TabStripMetrics`, `TabStripPolicy`), so the numbers are
/// one definition; these tests pin what the numbers are supposed to produce.
@MainActor
final class TabNameRowTests: XCTestCase {
    private var window: NSWindow!
    private var strip: HeaderTabStrip!

    override func setUp() {
        super.setUp()
        window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 900, height: 60))
        strip = HeaderTabStrip(
            frame: CGRect(x: 0, y: 0, width: 900, height: ChalkMetrics.tabStripHeight))
        window.addSubview(strip)
        window.isHidden = false
    }

    override func tearDown() {
        strip.removeFromSuperview()
        window.isHidden = true
        window = nil
        strip = nil
        super.tearDown()
    }

    private func tab(_ name: String, active: Bool = false, dirty: Bool = false,
                     preview: Bool = false) -> TabItem {
        TabItem(id: UUID(), name: name, isDirty: dirty, isActive: active, isPreview: preview)
    }

    private func settle() {
        strip.setNeedsLayout()
        strip.layoutIfNeeded()
    }

    // MARK: - The row is typography

    /// The artboard's rhythm: 28pt of air between one name and the next, made
    /// of each item's own 8pt padding plus the 12pt the row puts between them.
    /// Half of that is the window's drag surface on Mac, which is why the
    /// padding is not simply 14 on each side.
    func testNamesAreSeparatedByTheArtboardsGap() {
        let a = tab("alpha.md", active: true)
        let b = tab("beta.md")
        let c = tab("gamma.tex")
        strip.update([a, b, c])
        settle()

        let labelB = try! XCTUnwrap(strip.labelFrameForTesting(b.id))
        let labelC = try! XCTUnwrap(strip.labelFrameForTesting(c.id))
        XCTAssertEqual(labelC.minX - labelB.maxX,
                       ChalkMetrics.tabLabelPadding * 2 + ChalkMetrics.tabGap,
                       accuracy: 1.0,
                       "two background names are one 28pt gap apart")

        let itemB = try! XCTUnwrap(strip.tabFrameForTesting(b.id))
        XCTAssertEqual(itemB.minX, labelB.minX - ChalkMetrics.tabLabelPadding, accuracy: 1.0)
        XCTAssertEqual(itemB.maxX, labelB.maxX + ChalkMetrics.tabLabelPadding, accuracy: 1.0,
                       "a clean background tab ends at its label plus padding — no reserved slot")
        XCTAssertEqual(itemB.height, ChalkMetrics.tabStripHeight, accuracy: 1.0,
                       "the whole row height is the tab's click target")
    }

    /// The slot takes layout space where something rests in it, and nowhere
    /// else: the active tab (× or dot) and any unsaved tab (dot).
    func testOnlyTabsWithSomethingToShowReserveTheSlot() {
        let active = tab("alpha.md", active: true)
        let dirty = tab("beta.md", dirty: true)
        let clean = tab("gamma.tex")
        strip.update([active, dirty, clean])
        settle()

        func trailingRoom(_ id: UUID) -> CGFloat {
            let item = strip.tabFrameForTesting(id)!
            return item.maxX - strip.labelFrameForTesting(id)!.maxX
        }
        let reserved = ChalkMetrics.tabLabelPadding
            + ChalkMetrics.tabInnerGap + ChalkMetrics.tabSlotWidth
        XCTAssertEqual(trailingRoom(active.id), reserved, accuracy: 1.0)
        XCTAssertEqual(trailingRoom(dirty.id), reserved, accuracy: 1.0,
                       "unsaved work shows at rest on a background tab too")
        XCTAssertEqual(trailingRoom(clean.id), ChalkMetrics.tabLabelPadding, accuracy: 1.0)
    }

    // MARK: - The underline

    func testTheUnderlineSpansTheActiveLabelAndSitsBelowIt() {
        let a = tab("alpha.md", active: true)
        strip.update([a, tab("beta.md")])
        settle()

        let label = try! XCTUnwrap(strip.activeLabelFrameForTesting)
        let underline = try! XCTUnwrap(strip.activeUnderlineFrameForTesting)
        XCTAssertEqual(underline.minX, label.minX, accuracy: 1.0)
        XCTAssertEqual(underline.width, label.width, accuracy: 1.0,
                       "the underline is the label's width — it is a mark on the word, not a tab edge")
        XCTAssertEqual(underline.minY - label.maxY, ChalkMetrics.tabUnderlineGap, accuracy: 1.0)
        XCTAssertEqual(underline.height, ChalkMetrics.tabUnderlineHeight, accuracy: 0.5)
    }

    func testTheUnderlineFollowsTheActiveTab() {
        let a = tab("alpha.md", active: true)
        let b = tab("beta.md")
        strip.update([a, b])
        settle()
        let first = try! XCTUnwrap(strip.activeUnderlineFrameForTesting)

        strip.update([TabItem(id: a.id, name: "alpha.md", isDirty: false,
                              isActive: false, isPreview: false),
                      TabItem(id: b.id, name: "beta.md", isDirty: false,
                              isActive: true, isPreview: false)])
        settle()

        let labelB = try! XCTUnwrap(strip.labelFrameForTesting(b.id))
        let moved = try! XCTUnwrap(strip.activeUnderlineFrameForTesting)
        XCTAssertEqual(moved.minX, labelB.minX, accuracy: 1.0,
                       "the underline is the only mark that says which document you are in")
        XCTAssertGreaterThan(moved.minX, first.minX)
    }

    /// docs/motion.md, tab switch: the underline SLIDES to the new name. A
    /// rebuild that did not change the active tab must not animate — that is
    /// the resting chrome twitching (Y-19).
    func testTheUnderlineSlidesOnASwitchAndNotOnAPlainRebuild() {
        let a = tab("alpha.md", active: true)
        let b = tab("beta.md")
        strip.update([a, b])
        settle()
        XCTAssertFalse(strip.underlineIsAnimatingForTesting,
                       "first paint places the underline, it does not fly in")

        // Same active tab, new model (a dirty-marker flip): no motion.
        strip.update([TabItem(id: a.id, name: "alpha.md", isDirty: true,
                              isActive: true, isPreview: false), b])
        settle()
        XCTAssertFalse(strip.underlineIsAnimatingForTesting,
                       "a rebuild that kept the same active tab must not move the underline")

        strip.update([TabItem(id: a.id, name: "alpha.md", isDirty: true,
                              isActive: false, isPreview: false),
                      TabItem(id: b.id, name: "beta.md", isDirty: false,
                              isActive: true, isPreview: false)])
        settle()
        XCTAssertTrue(strip.underlineIsAnimatingForTesting,
                      "a switch slides the underline to the new name")
    }

    func testNoActiveTabMeansNoUnderline() {
        strip.update([tab("alpha.md"), tab("beta.md")])
        settle()
        XCTAssertNil(strip.activeUnderlineFrameForTesting,
                     "nothing is active, so nothing is underlined")
    }
}
