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
    /// For comparisons across measurement sources (live frame vs constant, or
    /// lengths through the Catalyst 1/0.77 scale): residuals are ~0.6pt
    /// (FooterPillPlacementTests), real defects 5pt and worse.
    private static let crossSourceEpsilon: CGFloat = 1.0

    private static func hasLibrary(_ layout: ChromeLayout) -> Bool {
        layout.libraryPanel != nil
    }

    private static func hasOutline(_ layout: ChromeLayout) -> Bool {
        layout.outlinePanel != nil
    }

    /// The UIKit tab band is actually hosted in this state.
    ///
    /// A hidden band (windowed, zen) reports `.zero` for `band`,
    /// `bandPaint` and `tabStrip`, so band-shape rules would fail spuriously.
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
    // `ChromeInvariantMatrixTests` walks all 32 cells of the state matrix on Mac Catalyst.
    // In each cell it asserts every rule that both APPLIES there and is FALSIFIABLE there.
    // A rule evaluated against absent geometry passes whatever the app did, so it is not counted as coverage and never reported as a pass.
    //
    // The matrix carries an outline axis: every cell exists with the outline panel open and closed, and the four `outlinePanel*` rules are evidence only in the open cells.
    //
    // EVERY cell asserts something falsifiable, and the blind-cell guard in the matrix test PASSES.
    // The utility pill stands in every state, so `pillRestsInTheCorner` is evidence everywhere rather than only where the pill happened to be showing.
    //
    // Coverage is still not uniform, and the differences are structural.
    // The counts below are the ones the suite PRINTS (`ChromeInvariantMatrixTests falsifiable coverage`), read off a run rather than reasoned about.
    //
    // | Cells | Falsifiable rules | Why |
    // | --- | --- | --- |
    // | full screen, normal, Library open, outline closed (2) | 15 of 19 | the row is the tab UI AND the strip decisions are recorded; the outline panel is closed |
    // | full screen, normal, Library open, outline open (2) | 19 of 19 | as above, plus the four `outlinePanel*` rules: every rule in the catalogue is evidence here |
    // | full screen, normal, Library closed, outline closed (2) | 11 of 19 | as above, minus the Library rules |
    // | full screen, normal, Library closed, outline open (2) | 15 of 19 | as above, plus the four `outlinePanel*` rules |
    // | windowed, normal, Library open, outline closed (2) | 10 of 19 | no UIKit row (the tabs are AppKit): the Library rules, the reserve, the pill, the content column and the four strip rules |
    // | windowed, normal, Library open, outline open (2) | 13 of 19 | as above, plus THREE of the four `outlinePanel*` rules: with no UIKit band there is no paint, so `outlinePanelIsNeverPaintedOver` has nothing to be wrong about |
    // | windowed, normal, Library closed, outline closed (2) | 8 of 19 | as above, minus the Library rules |
    // | windowed, normal, Library closed, outline open (2) | 11 of 19 | as above, plus the same three `outlinePanel*` rules |
    // | zen, outline closed (8) | 8 of 19 | resting reserve, pill, content column, window containment, plus the four strip rules |
    // | zen, outline open (8) | 8 of 19 | zen forces the outline panel closed regardless of the request, so its three rules are never evidence here |
    //
    // One gap this layer still cannot close, stated rather than averaged away: **the windowed tab row's PIXELS remain unasserted.**
    // The tabs live in an AppKit `NSToolbar` inside `ChalkAppKitGlue`, a runtime-loaded bundle no test target links.
    // What the `stripIs*`/`stripLeading*` rules assert is the app's half of that contract — the divider inset, visibility and fade the app DECIDED and posts to the glue (recorded at the post sites, before the scene-bound gate) — checked against `MacStripExpectation.forState`.
    // Whether the glue draws what it was told is pinned only as pure functions by `TitlebarBandGeometryTests`; nothing asserts the drawn result.
    // The same holds for the accent underline: `activeUnderlineTracksTheActiveName` sees the UIKit row (full screen), and the AppKit row's underline is pinned by ChalkKit's `ThemePalette` and `TabStripMetrics`, which the glue compiles in, not by this matrix.
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
                    leading = abs(layout.editorContent.minX - layout.root.minX - layout.safeLeading) < crossSourceEpsilon
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
                // Leading: the window edge, or the safe inset where the system
                // reserves one (Catalyst's column overhang).
                let leadingGap = panel.minX - layout.root.minX
                return leadingGap > -crossSourceEpsilon
                    && leadingGap < layout.safeLeading + crossSourceEpsilon
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
            name: "stripLeadingTracksTheDivider",
            rationale: "The windowed Mac tab chips start at the Library divider while the Library is tiled and return to the traffic lights when it hides; a stale inset leaves the tabs floating over the panel or parked mid-window after it closed.",
            // `macStrip` is nil unless the glue is loaded; its
            // divider is what `pushStripLeadingInset` last decided.
            appliesTo: { $0.macStrip != nil },
            isFalsifiable: { $0.macStrip != nil },
            holds: { layout in
                guard let strip = layout.macStrip else { return true }
                // The chips track the editor column's leading edge (what
                // `pushStripLeadingInset` reads), 1.5pt past the panel on
                // Catalyst, so the content column's minX is the oracle.
                let expected = MacStripExpectation.forState(
                    window: layout.state.window, sidebar: layout.state.sidebar,
                    mode: layout.state.mode, glueAvailable: true,
                    dividerX: layout.libraryPanel != nil ? layout.editorContent.minX : 0)
                return abs(strip.dividerX - expected.dividerX) < crossSourceEpsilon
            }),

        ChromeInvariant(
            name: "stripVisibilityMatchesTheState",
            rationale: "The titlebar strip's toolbar stands exactly when the state calls for it: full screen hands the tab row to the UIKit band, and zen keeps the toolbar standing while the chips fade. A recorded visibility that disagrees with the mode is a titlebar lying about the state — or a window that collapsed its content area in zen.",
            appliesTo: { $0.macStrip != nil },
            isFalsifiable: { $0.macStrip != nil },
            holds: { layout in
                guard let strip = layout.macStrip else { return true }
                let expected = MacStripExpectation.forState(
                    window: layout.state.window, sidebar: layout.state.sidebar,
                    mode: layout.state.mode, glueAvailable: true,
                    dividerX: layout.libraryPanel?.maxX ?? 0)
                return strip.visible == expected.visible
            }),

        ChromeInvariant(
            name: "stripFadeMatchesTheState",
            rationale: "Outside zen the fade belongs to an active auto-hide scroll run only — a strip still faded in a normal resting state is the stale-fade handover bug (TabChromeOwnership) wearing a new state. Zen's FADE lane is the one state that RESTS faded (the faded, glue-hidden strip is the zen titlebar), so an un-faded strip standing over zen fails the same rule from the other side.",
            appliesTo: { $0.macStrip != nil },
            isFalsifiable: { $0.macStrip != nil },
            holds: { layout in
                guard let strip = layout.macStrip else { return true }
                let expected = MacStripExpectation.forState(
                    window: layout.state.window, sidebar: layout.state.sidebar,
                    mode: layout.state.mode, glueAvailable: true,
                    dividerX: layout.libraryPanel?.maxX ?? 0)
                return strip.faded == expected.faded
            }),

        ChromeInvariant(
            name: "bandAndStripNeverBothCarryTheTabs",
            rationale: "One tab row, ever. The row moves between the app's UIKit band and the AppKit titlebar strip (TabChromeOwnership), and a handover that shows the new owner without quieting the old one puts the same tabs on screen twice — which is what the owner photographed on 2026-08-24: entering full screen hid the strip, the auto-hide re-application then posted an un-fade, and the un-fade un-hid it, so the revealed system titlebar carried a second tab row above the band.",
            appliesTo: { $0.macStrip != nil },
            isFalsifiable: { $0.macStrip != nil },
            holds: { layout in
                guard let strip = layout.macStrip else { return true }
                // A hidden band reports `.zero`.
                return !(strip.visible && !layout.band.isEmpty)
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
