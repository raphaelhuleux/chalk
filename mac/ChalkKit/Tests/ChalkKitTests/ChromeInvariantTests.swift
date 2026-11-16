import XCTest
@testable import ChalkKit

final class ChromeInvariantTests: XCTestCase {
    private let root = CGRect(x: 0, y: 0, width: 1000, height: 800)

    /// A full-screen layout (the UIKit band hosts the tabs) that satisfies
    /// every invariant, which each test then breaks in exactly one way. Building the good case once keeps each test about a
    /// single relationship.
    private func healthy(sidebar: Bool = true, outline: Bool = false, overlay: Bool = false,
                         split: Bool = false) -> ChromeLayout {
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
        var panes = [content]
        var dividers: [CGRect] = []
        let strip = CGRect(x: 350, y: 20, width: 400, height: 40)
        var strips = [strip]
        if split {
            // Three groups, as the matrix draws `.multiple`.
            let third = (content.width / 3).rounded(.down)
            panes = (0..<3).map { i in
                CGRect(x: content.minX + CGFloat(i) * third, y: content.minY,
                       width: i == 2 ? content.width - 2 * third : third, height: content.height)
            }
            dividers = panes.dropLast().map { CGRect(x: $0.maxX - 6, y: content.minY, width: 12, height: content.height) }
            strips = panes.enumerated().map { i, pane in
                let minX = i == 0 ? strip.minX : pane.minX + 14
                return CGRect(x: minX, y: strip.minY, width: pane.maxX - 14 - minX, height: strip.height)
            }
        }
        return ChromeLayout(
            state: UIState(window: .fullscreen,
                           sidebar: sidebar ? .shown : .hidden,
                           mode: .normal, groups: split ? .multiple : .single, appearance: .dark),
            root: root, band: band, bandPaint: band,
            bandPaintHole: panel.map { CGRect(x: 0, y: 0, width: $0.maxX, height: band.height) },
            libraryPanel: panel,
            tabStrip: strips[0],
            editorRestingTop: 87, restingPad: 27,
            libraryRowHeight: 34, underlineGap: 7,
            footerPill: CGRect(x: 18, y: 748, width: 200, height: 40),
            pillCorner: CGPoint(x: 18, y: 12),
            editorContent: content,
            reserveTop: band.maxY,
            // Full screen: no traffic lights, so the first area header rises
            // into the band to the panel's top padding.
            libraryFirstHeaderTop: sidebar ? root.minY + 24 : nil,
            activeTabLabel: label,
            activeTabUnderline: CGRect(x: label.minX, y: label.maxY + 5,
                                       width: label.width, height: 2),
            outlinePanel: outlinePanel,
            outlinePanelIsOverlay: overlay,
            outlinePanelPushMinimum: outline ? (overlay ? 500 : 200) : 0,
            bandPaintTrailingHole: outlinePanel.map { CGRect(x: $0.minX, y: 0, width: 1000 - $0.minX, height: band.height) },
            editorPanes: panes,
            groupDividers: dividers,
            groupMinimumWidth: 200,
            groupStrips: strips,
            // Every row's names on one line, the band's centre.
            nameLines: strips.map { _ in band.midY })
    }

    /// `healthy` windowed, with the lights on the names' line and the first name one gap past
    /// them. One group has no Library, so the row starts at the lights; three keep the Library,
    /// whose geometry `healthy` builds them around.
    private func windowedWithLights(split: Bool = false) -> ChromeLayout {
        var layout = healthy(sidebar: split, split: split)
        layout.state = UIState(window: .windowed, sidebar: split ? .shown : .hidden, mode: .normal,
                               groups: split ? .multiple : .single, appearance: .dark)
        layout.reserveTop = layout.band.maxY
        layout.libraryFirstHeaderTop = split ? layout.band.maxY + 4 : nil
        layout.trafficLights = CGRect(x: 19, y: layout.band.midY - 7, width: 60, height: 14)
        layout.trafficLightGap = 24
        layout.firstNameMinX = 19 + 60 + 24
        return layout
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
            libraryFirstHeaderTop: sidebar ? 56 : nil)
    }

    /// Fails on an unknown name, so a retired rule cannot leave a test that
    /// passes while asserting nothing.
    private func check(_ name: String, _ layout: ChromeLayout) -> Bool {
        rule(name).holds(layout)
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
                       macHealthy(sidebar: true), macHealthy(sidebar: false),
                       windowedWithLights(), windowedWithLights(split: true)] {
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

    func testNameRowClearsTheLibraryFailsWhenTheNamesOverlapIt() {
        var layout = healthy()
        layout.tabStrip = CGRect(x: 100, y: 20, width: 400, height: 40)
        XCTAssertFalse(check("nameRowClearsTheLibrary", layout))
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

    /// A header above the titlebar floor is a header sliding under the chrome.
    func testLibraryFloorRuleFailsWhenTheHeaderRidesUnderTheTitlebar() {
        var layout = macHealthy()
        XCTAssertTrue(rule("libraryListStartsAtTheChromeFloor").holds(layout))
        layout.libraryFirstHeaderTop = layout.reserveTop - 10
        XCTAssertFalse(rule("libraryListStartsAtTheChromeFloor").holds(layout))
    }

    /// Full screen has no traffic lights: a list still parked below the band
    /// leaves their empty strip over the Library.
    func testLibraryFloorRuleFailsWhenFullScreenKeepsTheLightsStrip() {
        var layout = healthy()
        XCTAssertTrue(rule("libraryListStartsAtTheChromeFloor").holds(layout))
        layout.libraryFirstHeaderTop = layout.band.maxY + 4
        XCTAssertFalse(rule("libraryListStartsAtTheChromeFloor").holds(layout))
    }

    /// The names off the lights' line: the short titlebar after a full-screen exit put the
    /// lights 7pt above them (docs/issues/2026-11-16-tab-row-regressions.md).
    func testNamesOffTheLightsLineFail() {
        var layout = windowedWithLights()
        XCTAssertTrue(rule("namesShareTheLightsLine").isEvidence(about: layout))
        XCTAssertTrue(check("namesShareTheLightsLine", layout))
        layout.trafficLights?.origin.y -= 7
        XCTAssertFalse(check("namesShareTheLightsLine", layout))
    }

    /// Full screen hides the lights: the rule says nothing there.
    func testTheLightsRulesDoNotApplyInFullScreen() {
        var layout = windowedWithLights()
        layout.state = UIState(window: .fullscreen, sidebar: .hidden, mode: .normal, appearance: .dark)
        XCTAssertFalse(rule("namesShareTheLightsLine").appliesTo(layout))
        XCTAssertFalse(rule("firstNameClearsTheLights").appliesTo(layout))
    }

    func testAFirstNameThatCrowdsOrLeavesTheLightsFails() {
        var layout = windowedWithLights()
        XCTAssertTrue(check("firstNameClearsTheLights", layout))
        layout.firstNameMinX! -= 8
        XCTAssertFalse(check("firstNameClearsTheLights", layout))
        layout.firstNameMinX! += 16
        XCTAssertFalse(check("firstNameClearsTheLights", layout))
    }

    func testAGroupRowOffTheLineFails() {
        var layout = windowedWithLights(split: true)
        XCTAssertTrue(rule("groupRowsShareOneLine").isEvidence(about: layout))
        XCTAssertTrue(check("groupRowsShareOneLine", layout))
        layout.nameLines[1] += 2
        XCTAssertFalse(check("groupRowsShareOneLine", layout))
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
        for layout in [healthy(sidebar: true), healthy(sidebar: false), healthy(split: true),
                       windowedWithLights(), windowedWithLights(split: true)] {
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

    // MARK: Groups

    func testHealthyGroupsSatisfyEveryInvariant() {
        for layout in [healthy(split: true), healthy(outline: true, split: true),
                       healthy(outline: true, overlay: true, split: true)] {
            for invariant in ChromeInvariant.catalogue where invariant.isEvidence(about: layout) {
                XCTAssertTrue(invariant.holds(layout), invariant.name)
            }
        }
    }

    func testPanesRuleFailsWhenTheGroupsStateShowsOnePane() {
        var layout = healthy(split: true)
        layout.editorPanes = [layout.editorContent]
        XCTAssertFalse(check("editorPanesTileTheContent", layout))
    }

    func testPanesRuleFailsWhenTheTrailingPaneStopsShort() {
        var layout = healthy(split: true)
        layout.editorPanes[2].size.width -= 20
        XCTAssertFalse(check("editorPanesTileTheContent", layout))
    }

    func testPanesRuleFailsWhenThePanesOverlap() {
        var layout = healthy(split: true)
        layout.editorPanes[0].size.width += 30
        XCTAssertFalse(check("editorPanesTileTheContent", layout))
    }

    func testPanesRuleFailsWhenASinglePaneMissesTheColumn() {
        var layout = healthy()
        layout.editorPanes = [layout.editorContent.insetBy(dx: 10, dy: 0)]
        XCTAssertFalse(check("editorPanesTileTheContent", layout))
    }

    func testFloorRuleFailsOnASliver() {
        var layout = healthy(split: true)
        let panes = layout.editorPanes
        layout.editorPanes[0].size.width = 80
        layout.editorPanes[1] = CGRect(x: panes[0].minX + 80, y: panes[1].minY,
                                       width: panes[1].maxX - panes[0].minX - 80, height: panes[1].height)
        XCTAssertFalse(check("editorGroupsKeepTheirFloor", layout))
    }

    func testFloorRuleAcceptsEvenSharesInANarrowColumn() {
        var layout = healthy(split: true)
        layout.groupMinimumWidth = layout.editorContent.width
        XCTAssertTrue(check("editorGroupsKeepTheirFloor", layout))
    }

    func testDividerRuleFailsAtAStaleX() {
        var layout = healthy(split: true)
        layout.groupDividers[1].origin.x += 40
        XCTAssertFalse(check("groupDividersSitOnTheSeams", layout))
    }

    func testDividerRuleFailsWhenASeamHasNoHandle() {
        var layout = healthy(split: true)
        layout.groupDividers.removeLast()
        XCTAssertFalse(check("groupDividersSitOnTheSeams", layout))
    }

    func testStripRuleFailsWhenARowCrossesIntoTheNextColumn() {
        var layout = healthy(split: true)
        layout.groupStrips[0].size.width += 100
        XCTAssertFalse(check("groupStripsLieOverTheirColumns", layout))
    }

    func testStripRuleFailsWhenARowStartsBeforeItsColumn() {
        var layout = healthy(split: true)
        layout.groupStrips[2].origin.x = layout.editorPanes[2].minX - 30
        XCTAssertFalse(check("groupStripsLieOverTheirColumns", layout))
    }

    func testStripRuleFailsWhenAGroupHasNoRow() {
        var layout = healthy(split: true)
        layout.groupStrips.removeLast()
        XCTAssertFalse(check("groupStripsLieOverTheirColumns", layout))
    }

    func testGroupRulesDoNotApplyToOneGroup() {
        let layout = healthy()
        XCTAssertFalse(rule("editorGroupsKeepTheirFloor").appliesTo(layout))
        XCTAssertFalse(rule("groupDividersSitOnTheSeams").appliesTo(layout))
        XCTAssertFalse(rule("groupStripsLieOverTheirColumns").appliesTo(layout))
    }
}
