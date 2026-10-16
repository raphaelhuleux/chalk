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
    // `ChromeInvariantMatrixTests` walks all 48 cells of the state matrix (`ChalkTests`).
    // In each cell it asserts every rule that both APPLIES there and is FALSIFIABLE there.
    // A rule evaluated against absent geometry passes whatever the app did, so it is not counted as coverage and never reported as a pass.
    //
    // The matrix carries a trailing-slot axis: every cell exists with the slot closed, showing the outline, and showing the PDF. The PDF shares the outline's frame, so the four `outlinePanel*` rules are evidence in every open cell, whichever content fills it.
    //
    // EVERY cell asserts something falsifiable, and the blind-cell guard in the matrix test PASSES.
    // The utility pill stands in every state, so `pillRestsInTheCorner` is evidence everywhere rather than only where the pill happened to be showing.
    // The matrix host seeds one Library folder, so every Library-open cell has a first area header for `libraryListStartsAtTheChromeFloor` to measure.
    //
    // Coverage is still not uniform, and the differences are structural.
    // The counts below are the ones the suite PRINTS (`ChromeInvariantMatrixTests falsifiable coverage`), read off a run rather than reasoned about.
    // Windowed and full screen are the same chrome (one band, drawn in the content view under a transparent titlebar), so their rows coincide.
    //
    // | Cells | Falsifiable rules | Why |
    // | --- | --- | --- |
    // | normal, Library open, slot open: outline or PDF (8) | 15 of 15 | the band and its paint, the three Library rules, the name row, the resting line, the pill, the content column, the underline, window containment, and the four `outlinePanel*` rules |
    // | normal, Library open, slot closed (4) | 11 of 15 | as above, minus the four `outlinePanel*` rules |
    // | normal, Library closed, slot open: outline or PDF (8) | 11 of 15 | as the first row, minus the three Library rules and the name row |
    // | normal, Library closed, slot closed (4) | 7 of 15 | the band and its paint, the resting line, the pill, the content column, the underline, window containment |
    // | zen, slot closed (8) | 4 of 15 | resting reserve, pill, content column, window containment: zen hides the band and closes the Library |
    // | zen, slot open: outline or PDF (16) | 4 of 15 | zen forces the slot closed regardless of the request, so its four rules are never evidence here |
    //
    // COVERAGE-DOC-END

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
            rationale: "The Library's first area header begins on the line the system titlebar ends on. The band is the titlebar, which spans the whole window, so the Library has nowhere to go but below it — the two columns start their content together on that line.",
            appliesTo: { hasLibrary($0) },
            // Needs a measured header (an empty Library has none) and a
            // reserve that was actually read.
            isFalsifiable: { $0.libraryFirstHeaderTop != nil && $0.reserveTop > 0 },
            holds: { layout in
                guard let header = layout.libraryFirstHeaderTop else { return true }
                // At the floor or up to one row below (the list keeps some
                // top padding); above it is a header under the chrome.
                let delta = header - layout.reserveTop
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
            isFalsifiable: { layout in
                [layout.band, layout.tabStrip, layout.libraryPanel, layout.footerPill, layout.outlinePanel]
                    .compactMap { $0 }
                    .contains { !$0.isEmpty }
            },
            holds: { layout in
                let outside = [layout.band, layout.tabStrip, layout.libraryPanel, layout.footerPill, layout.outlinePanel]
                    .compactMap { $0 }
                    .contains { !layout.root.insetBy(dx: -epsilon, dy: -epsilon).contains($0) }
                return !outside
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
    ]
}
