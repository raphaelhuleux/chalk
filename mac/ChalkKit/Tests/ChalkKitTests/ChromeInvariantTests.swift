import XCTest
@testable import ChalkKit

final class ChromeInvariantTests: XCTestCase {
    private let root = CGRect(x: 0, y: 0, width: 1000, height: 800)

    /// A full-screen layout (the UIKit band hosts the tabs) that satisfies
    /// every invariant, which each test then breaks in exactly one way. Building the good case once keeps each test about a
    /// single relationship.
    private func healthy(sidebar: Bool = true, outline: Bool = false, overlay: Bool = false) -> ChromeLayout {
        let band = CGRect(x: 0, y: 0, width: 1000, height: 60)
        // Paper: the Library is FLUSH — it reaches the window's leading, top
        // and bottom edges — and the cover is cut around the whole of it.
        let panel = sidebar ? CGRect(x: 0, y: 0, width: 350, height: 800) : nil
        let label = CGRect(x: 358, y: 22, width: 120, height: 16)
        let outlinePanel = outline ? CGRect(x: 700, y: 0, width: 300, height: 800) : nil
        // The full-width value: the column as it would be with the outline
        // hidden, or with it shown as an overlay (the panel floats over the
        // column instead of narrowing it).
        let fullWidthContent = CGRect(x: panel?.maxX ?? 0, y: 0,
                                      width: 1000 - (panel?.maxX ?? 0), height: 800)
        let content: CGRect
        if outline && !overlay {
            content = CGRect(x: panel?.maxX ?? 0, y: 0,
                             width: 700 - (panel?.maxX ?? 0), height: 800)
        } else {
            content = fullWidthContent
        }
        return ChromeLayout(
            state: UIState(window: .fullscreen,
                           sidebar: sidebar ? .shown : .hidden,
                           mode: .normal, appearance: .dark),
            root: root, band: band, bandPaint: band,
            bandPaintHole: panel.map { CGRect(x: 0, y: 0, width: $0.maxX, height: band.height) },
            libraryPanel: panel,
            tabStrip: CGRect(x: 350, y: 20, width: 400, height: 40),
            editorRestingTop: 87, restingPad: 27,
            libraryRowHeight: 34, underlineGap: 7,
            footerPill: CGRect(x: 18, y: 748, width: 200, height: 40),
            pillCorner: CGPoint(x: 18, y: 12),
            editorContent: content,
            reserveTop: band.maxY,
            safeLeading: 0,
            // The first area header sits just below the chrome floor.
            libraryFirstHeaderTop: sidebar ? band.maxY + 4 : nil,
            activeChip: CGRect(x: 350, y: 20, width: 140, height: 40),
            activeTabLabel: label,
            activeTabUnderline: CGRect(x: label.minX, y: label.maxY + 5,
                                       width: label.width, height: 2),
            outlinePanel: outlinePanel,
            outlinePanelIsOverlay: overlay,
            outlinePanelPushMinimum: outline ? (overlay ? 500 : 200) : 0,
            bandPaintTrailingHole: outlinePanel.map { CGRect(x: $0.minX, y: 0, width: 1000 - $0.minX, height: band.height) })
    }

    /// The windowed sibling: the band is the AppKit strip's business, so
    /// the UIKit rects are absent and the recorded strip decisions carry the
    /// evidence instead.
    private func macHealthy(sidebar: Bool = true) -> ChromeLayout {
        let panel = sidebar ? CGRect(x: 0, y: 0, width: 350, height: 800) : nil
        return ChromeLayout(
            state: UIState(window: .windowed,
                           sidebar: sidebar ? .shown : .hidden,
                           mode: .normal, appearance: .dark),
            root: root, band: .zero, bandPaint: .zero, bandPaintHole: nil,
            libraryPanel: panel, tabStrip: .zero,
            editorRestingTop: 79, restingPad: 27,
            libraryRowHeight: 30, underlineGap: 7,
            // Paper: the pill stands in every state.
            footerPill: CGRect(x: 15, y: 745, width: 200, height: 40),
            pillCorner: CGPoint(x: 15, y: 15),
            editorContent: CGRect(x: panel?.maxX ?? 0, y: 0,
                                  width: 1000 - (panel?.maxX ?? 0), height: 800),
            reserveTop: 52,
            safeLeading: 0,
            libraryFirstHeaderTop: sidebar ? 56 : nil)
    }

    private func check(_ name: String, _ layout: ChromeLayout) -> Bool {
        let invariant = ChromeInvariant.catalogue.first { $0.name == name }
        return invariant.map { $0.holds(layout) } ?? false
    }

    private func rule(_ name: String) -> ChromeInvariant {
        guard let found = ChromeInvariant.catalogue.first(where: { $0.name == name }) else {
            XCTFail("no invariant named \(name)")
            return ChromeInvariant(name: name, rationale: "", isFalsifiable: { _ in false }, holds: { _ in true })
        }
        return found
    }

    func testHealthyLayoutSatisfiesEveryInvariant() {
        for layout in [healthy(sidebar: true), healthy(sidebar: false),
                       macHealthy(sidebar: true), macHealthy(sidebar: false)] {
            for invariant in ChromeInvariant.catalogue where invariant.appliesTo(layout) {
                XCTAssertTrue(invariant.holds(layout),
                              "\(invariant.name) failed on a healthy layout")
            }
        }
    }

    /// Bugs 1 and 2: the band started at the sidebar divider.
    func testBandSpansFullWidthFailsWhenTheBandStartsAtTheDivider() {
        var layout = healthy()
        layout.band = CGRect(x: 350, y: 0, width: 650, height: 60)
        layout.bandPaint = layout.band
        XCTAssertFalse(check("bandSpansFullWidth", layout))
    }

    /// Bug 3: a full-width fill covered the Library panel.
    func testLibraryIsNeverPaintedOverFailsWithNoCutOut() {
        var layout = healthy()
        layout.bandPaintHole = nil
        XCTAssertFalse(check("libraryIsNeverPaintedOver", layout))
    }

    /// Bug 5: paint escaped below the band and drew a line across the sidebar.
    func testPaintStaysInsideTheBandFailsWhenPaintOverhangs() {
        var layout = healthy()
        layout.bandPaint = CGRect(x: 0, y: 0, width: 1000, height: 75)
        XCTAssertFalse(check("bandPaintStaysInsideTheBand", layout))
    }

    func testChipsStartAtTheEditorColumnFailsWhenTheyOverlapTheLibrary() {
        var layout = healthy()
        layout.tabStrip = CGRect(x: 100, y: 20, width: 400, height: 40)
        XCTAssertFalse(check("chipsClearTheLibrary", layout))
    }

    func testRestingLineFailsWhenItDoesNotClearTheReserve() {
        var layout = healthy()
        layout.editorRestingTop = 40
        XCTAssertFalse(check("restingLineSitsOneLineBelowTheReserve", layout))
    }

    /// The zen half of the generalized rule: a hidden band with an
    /// un-reclaimed resting offset leaves the text floating a band-height
    /// below nothing.
    func testRestingLineFailsWhenZenForgetsToReclaimTheOffset() {
        var layout = healthy()
        layout.band = .zero
        layout.bandPaint = .zero
        layout.reserveTop = 0          // nothing reserves in zen
        // editorRestingTop still 87: the un-reclaimed value.
        XCTAssertFalse(check("restingLineSitsOneLineBelowTheReserve", layout))
    }

    func testPillRuleFailsWhenThePillDriftsOffItsCorner() {
        var layout = healthy()
        layout.footerPill.origin.x += 6   // drifted off its corner
        XCTAssertFalse(check("pillRestsInTheCorner", layout))
        layout = healthy()
        layout.footerPill.origin.y -= 20  // parked above the corner
        XCTAssertFalse(check("pillRestsInTheCorner", layout))
    }

    func testEditorContentRuleFailsWhenTheColumnKeepsAStaleEdge() {
        var layout = healthy()
        // The hysteresis shape: the Library closed but the column still
        // starts at the old divider.
        layout.libraryPanel = nil
        layout.bandPaintHole = nil
        XCTAssertFalse(check("editorContentFillsTheColumn", layout))
        layout = healthy()
        layout.editorContent.size.width -= 30 // short of the trailing edge
        XCTAssertFalse(check("editorContentFillsTheColumn", layout))
    }

    func testActiveChipRuleFailsWhenTheChipMissesThePanelTop() {
        var layout = healthy()
        layout.activeChip?.origin.y += 5
        XCTAssertFalse(check("activeChipTopMeetsThePanelTop", layout))
    }

    /// A header above the titlebar floor is a header sliding under the chrome.
    func testLibraryFloorRuleFailsWhenTheHeaderRidesUnderTheTitlebar() {
        var layout = macHealthy()
        XCTAssertTrue(rule("libraryListStartsAtTheChromeFloor").holds(layout))
        layout.libraryFirstHeaderTop = layout.reserveTop - 10
        XCTAssertFalse(rule("libraryListStartsAtTheChromeFloor").holds(layout))
    }

    /// Invariants that only make sense with a Library must not run without one.
    func testLibraryInvariantsDoNotApplyWhenTheSidebarIsHidden() {
        let hidden = healthy(sidebar: false)
        for name in ["libraryIsNeverPaintedOver", "nameRowClearsTheLibrary",
                     "libraryListStartsAtTheChromeFloor", "libraryPanelReachesTheWindowEdges"] {
            let invariant = ChromeInvariant.catalogue.first { $0.name == name }
            XCTAssertEqual(invariant?.appliesTo(hidden), false, "\(name) should not apply")
        }
    }

    /// The zero-coverage guard's whole job. Before `isFalsifiable` existed,
    /// `chromeStaysInsideTheWindow` applied to every state and reduced to
    /// `root.contains(nothing)` when the chrome was absent, so a state with no
    /// chrome at all still scored one "asserted" invariant and the guard could
    /// never fire. Absent geometry is not evidence.
    func testAbsentGeometryOffersNoEvidence() {
        let absent = ChromeLayout(
            state: UIState(window: .windowed, sidebar: .hidden,
                           mode: .zen, appearance: .light),
            root: root, band: .zero, bandPaint: .zero, bandPaintHole: nil,
            libraryPanel: nil, tabStrip: .zero,
            // -1 is the reporting seam's "the editor was never handed a
            // value" sentinel; 0 is a legitimate zen resting top and would
            // wrongly count as evidence here.
            editorRestingTop: -1, restingPad: 27)
        for invariant in ChromeInvariant.catalogue {
            XCTAssertFalse(invariant.isEvidence(about: absent),
                           "\(invariant.name) claims to be evidence about a layout "
                           + "with no chrome in it; it can only pass")
        }
    }

    /// The other direction: a real layout must not be quietly discounted.
    /// Falsifiability that is too strict would hide coverage the suite has.
    func testAHealthyLayoutIsEvidenceForEveryRuleThatApplies() {
        for layout in [healthy(sidebar: true), healthy(sidebar: false)] {
            for invariant in ChromeInvariant.catalogue where invariant.appliesTo(layout) {
                XCTAssertTrue(invariant.isFalsifiable(layout),
                              "\(invariant.name) applies to a fully populated layout "
                              + "but claims it proves nothing")
            }
        }
    }

    func testEveryInvariantCarriesARationale() {
        for invariant in ChromeInvariant.catalogue {
            XCTAssertFalse(invariant.rationale.isEmpty,
                           "\(invariant.name) needs a rationale; the catalogue is documentation")
        }
    }

    func testHealthyLayoutWithTheOutlineOpenSatisfiesEveryInvariant() {
        for layout in [healthy(outline: true), healthy(outline: true, overlay: true)] {
            for invariant in ChromeInvariant.catalogue where invariant.isEvidence(about: layout) {
                XCTAssertTrue(invariant.holds(layout), invariant.name)
            }
        }
    }

    func testOutlinePanelRuleFailsWhenThePanelStopsShortOfTheTrailingEdge() {
        var layout = healthy(outline: true)
        layout.outlinePanel = CGRect(x: 680, y: 0, width: 300, height: 800)
        XCTAssertFalse(rule("outlinePanelReachesTheWindowEdges").holds(layout))
    }

    func testOutlineTopRuleFailsWhenThePanelDropsBelowTheEditorTop() {
        var layout = healthy(outline: true)
        layout.outlinePanel = CGRect(x: 700, y: 60, width: 300, height: 740)
        XCTAssertFalse(rule("outlinePanelSharesTheEditorTop").holds(layout))
    }

    func testEditorContentRuleFailsWhenThePushedColumnRunsUnderThePanel() {
        var layout = healthy(outline: true)
        layout.editorContent = CGRect(x: 350, y: 0, width: 650, height: 800)
        XCTAssertFalse(rule("editorContentFillsTheColumn").holds(layout))
    }

    func testEditorContentRuleFailsWhenTheOverlaidColumnStopsAtThePanel() {
        var layout = healthy(outline: true, overlay: true)
        layout.editorContent = CGRect(x: 350, y: 0, width: 350, height: 800)
        XCTAssertFalse(rule("editorContentFillsTheColumn").holds(layout))
    }

    func testOutlineModeRuleFailsWhenANarrowColumnStillPushes() {
        var layout = healthy(outline: true)
        layout.outlinePanelPushMinimum = 500
        XCTAssertFalse(rule("outlinePanelModeFollowsTheWidthFloor").holds(layout))
    }

    func testOutlineModeRuleFailsWhenAWideColumnOverlays() {
        var layout = healthy(outline: true, overlay: true)
        layout.outlinePanelPushMinimum = 200
        XCTAssertFalse(rule("outlinePanelModeFollowsTheWidthFloor").holds(layout))
    }

    func testOutlineInvariantsDoNotApplyWhenThePanelIsHidden() {
        let layout = healthy(outline: false)
        for name in ["outlinePanelReachesTheWindowEdges", "outlinePanelSharesTheEditorTop",
                     "outlinePanelModeFollowsTheWidthFloor"] {
            XCTAssertFalse(rule(name).isEvidence(about: layout), name)
        }
    }

    /// The outline panel is cut out of the band's paint exactly like the
    /// Library: a band painted across its top is the defect the owner saw on
    /// 2026-09-05 (the header hidden under the chips).
    func testOutlinePanelPaintRuleFailsWhenTheBandPaintsOverIt() {
        var layout = healthy(outline: true)
        XCTAssertTrue(rule("outlinePanelIsNeverPaintedOver").isEvidence(about: layout))
        XCTAssertTrue(rule("outlinePanelIsNeverPaintedOver").holds(layout))
        layout.bandPaintTrailingHole = nil
        XCTAssertFalse(rule("outlinePanelIsNeverPaintedOver").holds(layout))
    }

    func testOutlinePanelPaintRuleDoesNotApplyWhenThePanelIsHidden() {
        XCTAssertFalse(rule("outlinePanelIsNeverPaintedOver").isEvidence(about: healthy(outline: false)))
    }
}
