import XCTest
import ChalkKit
@testable import Chalk

/// The Settings rail is the shared left-hand navigation: "General", then one
/// row per LaTeX shortcut category under a banner.
///
/// Nothing in ChalkTests instantiated a settings controller before this file,
/// which is why the rail collapsing went unseen.
@MainActor
final class SettingsRailTests: XCTestCase {

    // MARK: - The rail's contents

    /// `SnippetLibrary.builtins` is a `lazy var` on a process-wide singleton
    /// fed by the bundled `latex.hsnips`. If that read ever returns nil the
    /// category list collapses AND the empty result is cached for the whole
    /// process — the rail then shows a banner with no rows under it, which is
    /// exactly "missing sections".
    func testBundledSnippetsAreReadable() throws {
        let raw = try XCTUnwrap(SnippetLibrary.bundledHsnips(),
                                "latex.hsnips must ship in the app bundle under editor/")
        XCTAssertFalse(raw.isEmpty)
    }

    func testBuiltinsAreNotEmpty() {
        XCTAssertFalse(SnippetLibrary.shared.builtins.isEmpty,
                       "an empty catalog collapses the whole LaTeX Shortcuts rail")
    }

    /// The General pane's Editor section: six rows, each rendering its label.
    /// A row that resolves to empty text paints as a bare control with nothing
    /// naming it — the same failure this file was written to catch on the rail.
    func testEditorSectionListsEverySetting() {
        let vc = GeneralSettingsViewController()
        XCTAssertEqual(vc.rowTitlesForTesting(section: 1),
                       ["Text Size", "Text Width", "Line Spacing", "Alignment",
                        "Color Markdown Headings", "New Documents", "View Mode"])
    }

    func testRailOffersGeneralAndEveryCategory() {
        let vc = SettingsContainerViewController()
        vc.loadViewIfNeeded()
        let titles = vc.railTitlesForTesting

        XCTAssertEqual(titles.first, ["General"], "the first section is General alone")
        XCTAssertGreaterThan(titles.count, 1, "the LaTeX Shortcuts section must exist")
        XCTAssertFalse(titles[1].isEmpty,
                       "the LaTeX Shortcuts banner must not sit over an empty section")
        XCTAssertTrue(titles[1].contains("Your Shortcuts"))
    }

    /// Every rail row must actually render its label. A row whose cell resolves
    /// to empty text paints as a bare pill — what a capture once showed for the
    /// selected "General" row.
    func testEveryRailRowRendersItsTitle() {
        let vc = SettingsContainerViewController()
        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(x: 0, y: 0, width: 900, height: 660)
        vc.view.layoutIfNeeded()

        for (section, rows) in vc.railTitlesForTesting.enumerated() {
            for (row, expected) in rows.enumerated() {
                let text = vc.railCellTextForTesting(section: section, row: row)
                XCTAssertEqual(text, expected,
                               "row \(section):\(row) must render \"\(expected)\", got \(text ?? "nil")")
            }
        }
    }

    // MARK: - Row height must fit the row font

    /// The rail row height was a hardcoded spec point, which clipped the
    /// labels ("only the lower half of their glyphs") wherever the row font
    /// grew past it.
    func testRailRowFitsItsLabel() {
        let lineHeight = UIFont.systemFont(ofSize: ChalkMetrics.sidebarRowFontSize).lineHeight
        XCTAssertGreaterThanOrEqual(
            ChalkMetrics.settingsRailRowHeight, lineHeight + ChalkMetrics.s(10),
            "the row must clear the label's line height plus breathing room")
    }
}

// MARK: - Rail row geometry

/// The rail labels were rendering as a 2pt smear. `UIListContentConfiguration`
/// keeps its own default vertical layout margins (~15pt top AND bottom), and
/// the cell builder mutated only `.leading` — so on a ~32pt row the label was
/// left about 2pt of height and the SF Symbol collapsed to 2x2.
///
/// Measured before the fix:
///   cell 190x31.9, UILabel "General" frame (60, 15, 55.5, **2.0**)
///
/// These assertions are on real laid-out frames, because every content-level
/// check passed while the screen was unreadable: the configuration carried the
/// right text the whole time.
@MainActor
final class SettingsRailGeometryTests: XCTestCase {
    private func laidOutRail() -> UITableView {
        let vc = SettingsContainerViewController()
        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(x: 0, y: 0, width: 900, height: 714)
        vc.view.layoutIfNeeded()
        let table = vc.railViewForTesting
        table.layoutIfNeeded()
        return table
    }

    private func labels(in cell: UITableViewCell) -> [UILabel] {
        var found: [UILabel] = []
        func walk(_ v: UIView) {
            for sub in v.subviews {
                if let label = sub as? UILabel, !(label.text ?? "").isEmpty { found.append(label) }
                walk(sub)
            }
        }
        walk(cell.contentView)
        return found
    }

    func testEveryRailLabelHasRoomForItsGlyphs() {
        let table = laidOutRail()
        var checked = 0
        for section in 0..<table.numberOfSections {
            for row in 0..<table.numberOfRows(inSection: section) {
                guard let cell = table.cellForRow(at: IndexPath(row: row, section: section))
                else { continue }
                for label in labels(in: cell) {
                    checked += 1
                    let needed = label.font.lineHeight
                    XCTAssertGreaterThanOrEqual(
                        label.bounds.height, needed - 0.5,
                        "\"\(label.text ?? "")\" has \(label.bounds.height)pt for a \(needed)pt line")
                }
            }
        }
        XCTAssertGreaterThan(checked, 1, "the rail must actually have rows to check")
    }

    func testRailLabelsFitInsideTheirRow() {
        let table = laidOutRail()
        for section in 0..<table.numberOfSections {
            for row in 0..<table.numberOfRows(inSection: section) {
                guard let cell = table.cellForRow(at: IndexPath(row: row, section: section))
                else { continue }
                for label in labels(in: cell) {
                    let inCell = label.convert(label.bounds, to: cell.contentView)
                    XCTAssertGreaterThanOrEqual(inCell.minY, -0.5, "label clipped at the top")
                    XCTAssertLessThanOrEqual(
                        inCell.maxY, cell.contentView.bounds.height + 0.5,
                        "label clipped at the bottom")
                }
            }
        }
    }

    /// The rail gives ground on a narrow container instead of eating a third of
    /// it; on a roomy one it keeps the spec width.
    /// Container widths go through `s()` like every other length here.
    ///
    /// A bare 900 is an unscaled number: the same physical container is
    /// 900/0.77 UIKit points wide, so a bare 900 describes a much narrower
    /// window there and the quarter-of-the-container cap bites. The rail then
    /// returned 225 where the test wanted s(190) = 246.75, which is the cap
    /// working correctly on a window the test did not mean to describe.
    func testRailWidthAdaptsToTheContainer() {
        XCTAssertEqual(SettingsPresentation.railWidth(forContainerWidth: ChalkMetrics.s(900)),
                       ChalkMetrics.s(190), accuracy: 0.5,
                       "a roomy container gets the spec width")
        XCTAssertLessThan(SettingsPresentation.railWidth(forContainerWidth: ChalkMetrics.s(540)),
                          ChalkMetrics.s(190),
                          "a narrow container gives ground instead of eating a third of itself")
        XCTAssertGreaterThanOrEqual(
            SettingsPresentation.railWidth(forContainerWidth: ChalkMetrics.s(320)),
            ChalkMetrics.s(120),
            "but never below the floor that still fits a category name")
    }
}
