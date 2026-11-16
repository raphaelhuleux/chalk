import Foundation

/// One named rule about how the chrome fits together. The name is shared
/// vocabulary: it appears in failures and in the generated catalogue.
public struct ChromeInvariant: Sendable {
    public let name: String
    /// Why the rule exists. Rendered into docs/ui-invariants.md.
    public let rationale: String
    /// States the rule is meaningful in (a Library rule says nothing when the
    /// Library is hidden).
    public let appliesTo: @Sendable (ChromeLayout) -> Bool
    /// Whether this layout gives `holds` something it could be wrong about.
    ///
    /// Separate from `appliesTo`: a rule evaluated against absent geometry
    /// (`root.contains(.zero)`) passes whatever the app did, so it must not
    /// count as coverage. No default: a wrong `true` here is invisible.
    public let isFalsifiable: @Sendable (ChromeLayout) -> Bool
    public let holds: @Sendable (ChromeLayout) -> Bool

    public init(name: String, rationale: String,
                appliesTo: @escaping @Sendable (ChromeLayout) -> Bool = { _ in true },
                isFalsifiable: @escaping @Sendable (ChromeLayout) -> Bool,
                holds: @escaping @Sendable (ChromeLayout) -> Bool) {
        self.name = name
        self.rationale = rationale
        self.appliesTo = appliesTo
        self.isFalsifiable = isFalsifiable
        self.holds = holds
    }

    /// Applicable AND falsifiable: the only combination that counts as an
    /// asserted invariant. Gate on this, not on `appliesTo` alone.
    public func isEvidence(about layout: ChromeLayout) -> Bool {
        appliesTo(layout) && isFalsifiable(layout)
    }

    private static let epsilon: CGFloat = 0.5
    /// For comparisons across measurement sources (live frame vs constant):
    /// residuals are under 1pt (FooterPillPlacementTests), real defects 5pt
    /// and worse.
    private static let crossSourceEpsilon: CGFloat = 1.0

    private static func hasLibrary(_ layout: ChromeLayout) -> Bool {
        layout.libraryPanel != nil
    }

    private static func hasOutline(_ layout: ChromeLayout) -> Bool {
        layout.outlinePanel != nil
    }

    /// The tab band is actually hosted in this state.
    ///
    /// A hidden band (zen) reports `.zero` for `band`, `bandPaint` and
    /// `tabStrip`, so band-shape rules would fail spuriously.
    private static func bandIsHosted(_ layout: ChromeLayout) -> Bool {
        !layout.band.isEmpty
    }

    // MARK: - Coverage
    //
    // The text between the markers is spliced verbatim into
    // docs/ui-invariants.md by scripts/generate-ui-invariants.mjs; editing one
    // without the other fails `--check` in scripts/check.sh.
    //
    // COVERAGE-DOC-BEGIN
    // ## Where each rule is actually asserted
    //
    // `ChromeInvariantMatrixTests` walks all 128 cells of the state matrix (`ChalkTests`).
    // In each cell it asserts every rule that both APPLIES there and is FALSIFIABLE there.
    // A rule evaluated against absent geometry passes whatever the app did, so it is not counted as coverage and never reported as a pass.
    //
    // The matrix carries a trailing-slot axis: every cell exists with the slot closed, showing the outline, showing the PDF, and showing both. One frame holds them, so the four `outlinePanel*` rules are evidence in every open cell, whichever content fills it.
    //
    // It also carries a groups axis: every cell exists with one tab group and with three. A three-group cell opens three draft tabs and splits twice, so three real web views share the column and the band holds three rows (the first row's inset, an interior row and the last row's outline cut). `editorPanesTileTheContent` is evidence in every cell; the four group rules (`editorGroupsKeepTheirFloor`, `groupDividersSitOnTheSeams`, `groupStripsLieOverTheirColumns`, `groupRowsShareOneLine`) only where the band and the groups both show.
    //
    // The roots are hosted in the app's own window (`EditorWindowController.makeChromeWindow`), so the traffic lights are real. The two lights rules are evidence only windowed: the matrix's full screen is a flag on a window that keeps its lights, so it says nothing about them there.
    //
    // EVERY cell asserts something falsifiable, and the blind-cell guard in the matrix test PASSES.
    // The utility pill stands in every state, so `pillRestsInTheCorner` is evidence everywhere rather than only where the pill happened to be showing.
    // The matrix host seeds one Library folder, so every Library-open cell has a first area header for `libraryListStartsAtTheChromeFloor` to measure.
    //
    // Coverage is still not uniform, and the differences are structural.
    // The counts below are the ones the suite PRINTS (`ChromeInvariantMatrixTests falsifiable coverage`), read off a run rather than reasoned about.
    // Each row holds its one-group cells; the same cells with three groups assert the group rules on top: add 4 where the band shows, 2 in zen (no rows to measure).
    //
    // | Cells (one group; as many again with three) | Falsifiable rules, one group / three | Why |
    // | --- | --- | --- |
    // | windowed, Library open, slot open: outline, PDF or both (6) | 17 / 21 of 22 | the band and its paint, the three Library rules, the name row, the resting line, the pill, the content column, the panes, the underline, window containment, the four `outlinePanel*` rules, and the names on the lights' line |
    // | full screen, Library open, slot open (6) | 16 / 20 of 22 | as above, minus the lights |
    // | windowed, Library open, slot closed (2) | 13 / 17 of 22 | as the first row, minus the four `outlinePanel*` rules |
    // | full screen, Library open, slot closed (2) | 12 / 16 of 22 | as above, minus the lights |
    // | windowed, Library closed, slot open (6) | 14 / 18 of 22 | as the first row, minus the three Library rules and the name row, plus the first name's gap from the lights |
    // | full screen, Library closed, slot open (6) | 12 / 16 of 22 | as above, minus both lights rules |
    // | windowed, Library closed, slot closed (2) | 10 / 14 of 22 | the band and its paint, the resting line, the pill, the content column, the panes, the underline, window containment, both lights rules |
    // | full screen, Library closed, slot closed (2) | 8 / 12 of 22 | as above, minus the lights |
    // | zen, any slot (32) | 5 / 7 of 22 | resting reserve, pill, content column, panes, window containment: zen hides the band, closes the Library and forces the slot closed |
    //
    // COVERAGE-DOC-END

    /// Every chrome rect that must stay inside the window. `groupStrips[0]` is `tabStrip`.
    private static func chromeRects(_ layout: ChromeLayout) -> [CGRect] {
        [layout.band, layout.tabStrip, layout.libraryPanel, layout.footerPill, layout.outlinePanel]
            .compactMap { $0 } + layout.groupStrips.dropFirst()
    }

    /// Every rule the chrome must satisfy.
    public static let catalogue: [ChromeInvariant] = [
        ChromeInvariant(
            name: "bandSpansFullWidth",
            rationale: "The tab row's opaque cover is one surface across the whole window. It stops nothing and reads as nothing (Paper paints it in the editor's own tone), but it has to span: a cover that ends at the sidebar divider lets full-bleed text surface beside the names, and a cover that ends anywhere else draws an edge across the paper.",
            appliesTo: { bandIsHosted($0) },
            isFalsifiable: { _ in true },
            holds: { abs($0.band.minX - $0.root.minX) < epsilon
                  && abs($0.band.maxX - $0.root.maxX) < epsilon }),

        ChromeInvariant(
            name: "bandPaintStaysInsideTheBand",
            rationale: "The band's opaque region never extends past the band itself. Paint escaping below it draws a line across whatever sits underneath.",
            appliesTo: { bandIsHosted($0) },
            // An unpainted band passes the guard for free.
            isFalsifiable: { !$0.bandPaint.isEmpty },
            holds: { layout in
                guard !layout.bandPaint.isEmpty else { return true }  // nothing painted, nothing to escape
                return layout.band.insetBy(dx: -epsilon, dy: -epsilon).contains(layout.bandPaint)
            }),

        ChromeInvariant(
            name: "libraryIsNeverPaintedOver",
            rationale: "The Library panel keeps its own surface. The band runs behind it, which means the panel is cut out of the paint rather than drawn over.",
            appliesTo: { hasLibrary($0) },
            // With no paint, `paintCovers` is false for every rect.
            isFalsifiable: { !$0.bandPaint.isEmpty },
            holds: { layout in
                guard let panel = layout.libraryPanel else { return true }
                return !layout.paintCovers(panel)
            }),

        ChromeInvariant(
            name: "outlinePanelIsNeverPaintedOver",
            rationale: "The outline panel keeps its own surface, like the Library: the band runs behind it, so the panel is cut out of the paint on the trailing edge rather than drawn over. A band across its top hides the panel's header under the chips.",
            appliesTo: { hasOutline($0) },
            isFalsifiable: { hasOutline($0) && !$0.bandPaint.isEmpty },
            holds: { layout in
                guard let panel = layout.outlinePanel else { return true }
                return !layout.paintCovers(panel)
            }),

        ChromeInvariant(
            name: "nameRowClearsTheLibrary",
            rationale: "The tab names start at the editor column. A name over the Library would sit on a surface it does not belong to, even though the cover behind it spans the window.",
            // Without a hosted band the strip is `.zero`, at x = 0.
            appliesTo: { hasLibrary($0) && bandIsHosted($0) },
            isFalsifiable: { !$0.tabStrip.isEmpty },
            holds: { layout in
                guard let panel = layout.libraryPanel else { return true }
                return layout.tabStrip.minX >= panel.maxX - epsilon
            }),

        ChromeInvariant(
            name: "restingLineSitsOneLineBelowTheReserve",
            rationale: "The document's first line rests one editor line below whatever chrome reserves space above the text: the tab band where it is hosted, the system titlebar on a windowed Mac, and nothing at all in zen, where the text rises to the top pad.",
            // `reserveTop` must come from independent truth, never from the
            // formula behind `editorRestingTop`, or this is a tautology. A
            // resting top below 0 means the editor was never handed a value.
            isFalsifiable: { $0.editorRestingTop >= 0 },
            holds: { abs($0.editorRestingTop - ($0.reserveTop + $0.restingPad)) < crossSourceEpsilon }),

        ChromeInvariant(
            name: "pillRestsInTheCorner",
            rationale: "The utility pill rests at the same corner offsets in every state, zen included: since Paper it is the ONLY home for the chrome buttons (the Library holds files and nothing else), so it never hands off, never hides, and a pill that drifts with a chrome transition reads as a control that wanders.",
            // A hidden pill reports `.zero` and proves nothing. The pill
            // stands in every state, so absence is a regression elsewhere.
            isFalsifiable: { !$0.footerPill.isEmpty && $0.pillCorner != .zero },
            holds: { layout in
                guard !layout.footerPill.isEmpty else { return true }
                return layout.root.insetBy(dx: -crossSourceEpsilon, dy: -crossSourceEpsilon)
                    .contains(layout.footerPill)
                    && abs(layout.footerPill.minX - layout.root.minX - layout.pillCorner.x) < crossSourceEpsilon
                    && abs(layout.root.maxY - layout.footerPill.maxY - layout.pillCorner.y) < crossSourceEpsilon
            }),

        ChromeInvariant(
            name: "editorContentFillsTheColumn",
            rationale: "The editor's content column reaches the window's trailing edge and starts at the Library divider while the Library is tiled, at the safe-area leading edge otherwise; a column pinned to a stale edge moves every line of text, not just the first. With the outline panel pushed open the column ends at the panel's leading edge instead; in overlay mode it keeps the window edge and the panel floats over it.",
            isFalsifiable: { !$0.editorContent.isEmpty },
            holds: { layout in
                guard !layout.editorContent.isEmpty else { return true }
                let expectedTrailingX: CGFloat
                if let panel = layout.outlinePanel, !layout.outlinePanelIsOverlay {
                    expectedTrailingX = panel.minX
                } else {
                    expectedTrailingX = layout.root.maxX
                }
                let trailing = abs(layout.editorContent.maxX - expectedTrailingX) < crossSourceEpsilon
                let leading: Bool
                if let panel = layout.libraryPanel {
                    // Content starts just past the panel's 1.5pt split-view
                    // gutter. 0...2 admits it and still fails the 5pt+
                    // stale-edge class.
                    let gap = layout.editorContent.minX - panel.maxX
                    leading = gap > -crossSourceEpsilon && gap < 2 + epsilon
                } else {
                    leading = abs(layout.editorContent.minX - layout.root.minX) < crossSourceEpsilon
                }
                return trailing && leading
            }),

        ChromeInvariant(
            name: "libraryListStartsAtTheChromeFloor",
            rationale: "Windowed, the Library's first area header begins on the line the system titlebar ends on: the band is the titlebar, which spans the whole window and holds the traffic lights above the Library, so the two columns start their content together on that line. In full screen there are no traffic lights, so the list rises into the band and starts at the top of its panel instead of leaving the lights' empty strip.",
            appliesTo: { hasLibrary($0) },
            // Needs a measured header (an empty Library has none) and, while
            // windowed, a reserve that was actually read.
            isFalsifiable: { $0.libraryFirstHeaderTop != nil && ($0.state.window == .fullscreen || $0.reserveTop > 0) },
            holds: { layout in
                guard let header = layout.libraryFirstHeaderTop else { return true }
                let floor = layout.state.window == .fullscreen ? layout.root.minY : layout.reserveTop
                // At the floor or up to one row below (the list keeps some
                // top padding); above it is a header under the chrome.
                let delta = header - floor
                return delta > -crossSourceEpsilon && delta < layout.libraryRowHeight
            }),

        ChromeInvariant(
            name: "libraryPanelReachesTheWindowEdges",
            rationale: "Paper's Library is flush: its surface runs to the window's leading, top and bottom edges. A panel that stops short reads as a floating card again — which is the treatment the direction removed.",
            appliesTo: { hasLibrary($0) },
            isFalsifiable: { ($0.libraryPanel.map { !$0.isEmpty }) ?? false },
            holds: { layout in
                guard let panel = layout.libraryPanel else { return true }
                return abs(panel.minX - layout.root.minX) < crossSourceEpsilon
                    && abs(panel.minY - layout.root.minY) < crossSourceEpsilon
                    && abs(panel.maxY - layout.root.maxY) < crossSourceEpsilon
            }),

        ChromeInvariant(
            name: "activeUnderlineTracksTheActiveName",
            rationale: "The accent underline sits under the ACTIVE tab's label, spanning exactly it, one fixed gap below. It is the only mark that says which document you are in now that the chip is gone, so an underline that outruns its label, misses it, or lingers under the previous one is the tab row lying about the state.",
            appliesTo: { $0.activeTabUnderline != nil },
            isFalsifiable: { layout in
                guard let underline = layout.activeTabUnderline,
                      let label = layout.activeTabLabel else { return false }
                return !underline.isEmpty && !label.isEmpty
            },
            holds: { layout in
                guard let underline = layout.activeTabUnderline,
                      let label = layout.activeTabLabel else { return true }
                return abs(underline.minX - label.minX) < crossSourceEpsilon
                    && abs(underline.width - label.width) < crossSourceEpsilon
                    && underline.minY > label.maxY - crossSourceEpsilon
                    && underline.minY < label.maxY + layout.underlineGap + crossSourceEpsilon
            }),

        ChromeInvariant(
            name: "chromeStaysInsideTheWindow",
            rationale: "No chrome element hangs outside the window's bounds, which is how an off-screen column or a clipped strip first shows up.",
            // Applies everywhere, but with every rect absent it reduces to
            // `root.contains(nothing)`, true by construction.
            isFalsifiable: { chromeRects($0).contains { !$0.isEmpty } },
            holds: { layout in
                let window = layout.root.insetBy(dx: -epsilon, dy: -epsilon)
                return chromeRects(layout).allSatisfy { window.contains($0) }
            }),

        ChromeInvariant(
            name: "outlinePanelReachesTheWindowEdges",
            rationale: "The outline panel is the Library's mirror on the trailing side: flush with the window's trailing and bottom edges. A panel that stops short reads as a floating card, which is the treatment the palette already has and this panel exists to replace.",
            appliesTo: { hasOutline($0) },
            isFalsifiable: { ($0.outlinePanel.map { !$0.isEmpty }) ?? false },
            holds: { layout in
                guard let panel = layout.outlinePanel else { return true }
                return abs(panel.maxX - layout.root.maxX) < crossSourceEpsilon
                    && abs(panel.maxY - layout.root.maxY) < crossSourceEpsilon
            }),

        ChromeInvariant(
            name: "outlinePanelSharesTheEditorTop",
            rationale: "The panel starts where the editor's content column starts: full-bleed under the transparent titlebar. A panel pinned to the safe area instead opens a dead strip above it.",
            appliesTo: { hasOutline($0) && !$0.editorContent.isEmpty },
            isFalsifiable: { hasOutline($0) && !$0.editorContent.isEmpty },
            holds: { layout in
                guard let panel = layout.outlinePanel else { return true }
                return abs(panel.minY - layout.editorContent.minY) < crossSourceEpsilon
            }),

        ChromeInvariant(
            name: "outlinePanelModeFollowsTheWidthFloor",
            rationale: "The panel pushes the editor while the column can spare the width and overlays it once the text would drop below the readable floor. The floor is the metrics table's number, so a panel that pushes a 300pt column or overlays a 900pt one is applying the wrong rule.",
            appliesTo: { hasOutline($0) && !$0.editorContent.isEmpty && $0.outlinePanelPushMinimum > 0 },
            isFalsifiable: { hasOutline($0) && !$0.editorContent.isEmpty && $0.outlinePanelPushMinimum > 0 },
            holds: { layout in
                guard let panel = layout.outlinePanel else { return true }
                let column = layout.outlinePanelIsOverlay
                    ? layout.editorContent.width
                    : layout.editorContent.width + panel.width
                let shouldOverlay = column - panel.width < layout.outlinePanelPushMinimum
                return shouldOverlay == layout.outlinePanelIsOverlay
            }),

        ChromeInvariant(
            name: "editorPanesTileTheContent",
            rationale: "The editor panes cover the content column exactly: one pane per tab group, neighbours meeting at one seam with no gap or overlap, all sharing its top and bottom. A pane that stops short shows bare background beside the text; panes that overlap hide one document's edge under another.",
            isFalsifiable: { !$0.editorContent.isEmpty && !$0.editorPanes.isEmpty },
            holds: { layout in
                let content = layout.editorContent
                let panes = layout.editorPanes
                guard !content.isEmpty, let first = panes.first, let last = panes.last else { return true }
                let expected = layout.state.groups == .multiple ? UIState.GroupsState.multipleCount : 1
                guard panes.count == expected else { return false }
                let spans = panes.allSatisfy {
                    abs($0.minY - content.minY) < epsilon && abs($0.maxY - content.maxY) < epsilon
                }
                let seams = zip(panes, panes.dropFirst()).allSatisfy { abs($0.maxX - $1.minX) < epsilon }
                return spans && seams
                    && abs(first.minX - content.minX) < epsilon
                    && abs(last.maxX - content.maxX) < epsilon
            }),

        ChromeInvariant(
            name: "editorGroupsKeepTheirFloor",
            rationale: "Each tab group keeps the metrics table's minimum width, so a dragged divider can never squeeze one document into an unreadable sliver. A column too narrow for every group's minimum shares itself evenly instead.",
            appliesTo: { $0.state.groups == .multiple },
            isFalsifiable: { $0.editorPanes.count > 1 && $0.groupMinimumWidth > 0 },
            holds: { layout in
                let panes = layout.editorPanes
                guard panes.count > 1 else { return true }
                let floor = layout.groupMinimumWidth
                let allKeepFloor = panes.allSatisfy { $0.width > floor - epsilon }
                // Even shares are whole points, the last taking the remainder: up to one point per
                // other group.
                let widths = panes.map(\.width)
                let even = (widths.max()! - widths.min()!) < CGFloat(panes.count - 1) + epsilon
                return allKeepFloor || (layout.editorContent.width < CGFloat(panes.count) * floor && even)
            }),

        ChromeInvariant(
            name: "groupDividersSitOnTheSeams",
            rationale: "Each drag handle straddles the seam between two neighbouring groups and runs their full height, one per seam. A handle left at a stale x catches drags where no edge is drawn, and the visible edge stops responding.",
            appliesTo: { $0.state.groups == .multiple },
            isFalsifiable: { $0.editorPanes.count > 1 && !$0.groupDividers.isEmpty },
            holds: { layout in
                let panes = layout.editorPanes
                guard panes.count > 1 else { return true }
                guard layout.groupDividers.count == panes.count - 1 else { return false }
                return zip(panes, layout.groupDividers).allSatisfy { pane, divider in
                    abs(divider.midX - pane.maxX) < epsilon
                        && abs(divider.minY - layout.editorContent.minY) < epsilon
                        && abs(divider.maxY - layout.editorContent.maxY) < epsilon
                }
            }),

        ChromeInvariant(
            name: "groupStripsLieOverTheirColumns",
            rationale: "Each tab group's row of names sits over its own column: one row per group, in pane order, none starting before its group's leading seam nor reaching past the next group's. A row that strays reads as the neighbour's tabs, and a click on it acts on the wrong group.",
            appliesTo: { $0.state.groups == .multiple },
            isFalsifiable: { $0.editorPanes.count > 1 && !$0.groupStrips.isEmpty },
            holds: { layout in
                let panes = layout.editorPanes
                let strips = layout.groupStrips
                guard panes.count > 1, !strips.isEmpty else { return true }
                guard strips.count == panes.count else { return false }
                for (i, strip) in strips.enumerated() {
                    if i > 0, strip.minX < panes[i].minX - epsilon { return false }
                    if i < panes.count - 1, strip.maxX > panes[i + 1].minX + epsilon { return false }
                }
                return true
            }),

        ChromeInvariant(
            name: "namesShareTheLightsLine",
            rationale: "Windowed, the tab names sit on the traffic lights' centre line: the middle of a capital is level with the middle of the lights. The band is centred on the titlebar, so this breaks whenever the titlebar is not the tall one the band was built for (a full-screen exit once brought it back short and left the lights 7pt above the names).",
            appliesTo: { bandIsHosted($0) && $0.state.window == .windowed && $0.trafficLights != nil },
            isFalsifiable: { $0.trafficLights != nil && !$0.nameLines.isEmpty },
            holds: { layout in
                guard let lights = layout.trafficLights, let line = layout.nameLines.first else { return true }
                return abs(lights.midY - line) <= crossSourceEpsilon
            }),

        ChromeInvariant(
            name: "firstNameClearsTheLights",
            rationale: "With no Library, the first name starts one fixed gap past the zoom button, read off the window's own lights. Closer and the name crowds the buttons; further and the row looks detached from the window's corner.",
            appliesTo: { bandIsHosted($0) && $0.state.window == .windowed && !hasLibrary($0) && $0.trafficLights != nil },
            isFalsifiable: { $0.trafficLights != nil && $0.firstNameMinX != nil && $0.trafficLightGap > 0 },
            holds: { layout in
                guard let lights = layout.trafficLights, let x = layout.firstNameMinX else { return true }
                return abs(x - lights.maxX - layout.trafficLightGap) <= crossSourceEpsilon
            }),

        ChromeInvariant(
            name: "groupRowsShareOneLine",
            rationale: "Every tab group's row of names sits on one line across the band. A row a point off reads as a second, unrelated bar.",
            appliesTo: { bandIsHosted($0) && $0.state.groups == .multiple },
            isFalsifiable: { $0.nameLines.count > 1 },
            holds: { layout in
                guard let first = layout.nameLines.first else { return true }
                return layout.nameLines.allSatisfy { abs($0 - first) <= epsilon }
            }),
    ]
}
