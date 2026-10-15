import XCTest
import ChalkKit
@testable import ChalkMac

/// The Settings rail is the shared left-hand navigation: "General", then one
/// row per LaTeX shortcut category under a banner.
@MainActor
final class SettingsRailTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { dismantleHostedSidebar(window) }
        windows = []
        super.tearDown()
    }

    // MARK: - The rail's contents

    /// `SnippetLibrary.builtins` is a `lazy var` on a process-wide singleton
    /// fed by the bundled `latex.hsnips`. If that read ever returns nil the
    /// category list collapses AND the empty result is cached for the whole
    /// process: the rail then shows a banner with no rows under it.
    func testBundledSnippetsAreReadable() throws {
        let raw = try XCTUnwrap(SnippetLibrary.bundledHsnips(),
                                "latex.hsnips must ship in the app bundle under editor/")
        XCTAssertFalse(raw.isEmpty)
    }

    func testBuiltinsAreNotEmpty() {
        XCTAssertFalse(SnippetLibrary.shared.builtins.isEmpty,
                       "an empty catalog collapses the whole LaTeX Shortcuts rail")
    }

    /// The General pane's Editor section: seven rows, each rendering its label.
    func testEditorSectionListsEverySetting() {
        let vc = GeneralSettingsViewController()
        XCTAssertEqual(vc.rowTitlesForTesting(section: 1),
                       ["Text Size", "Text Width", "Line Spacing", "Alignment",
                        "Color Markdown Headings", "New Documents", "View Mode"])
        XCTAssertEqual(vc.rowTitlesForTesting(section: 0), ["Appearance", "Theme", "Auto-hide Tabs"])
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
        XCTAssertEqual(vc.railRowTitlesForTesting[1], "LaTeX Shortcuts", "the banner sits between")
    }

    /// Every rail row must actually render its label. A row whose cell resolves
    /// to empty text paints as a bare pill.
    func testEveryRailRowRendersItsTitle() {
        let vc = hosted()
        for (section, rows) in vc.railTitlesForTesting.enumerated() {
            for (row, expected) in rows.enumerated() {
                let text = vc.railCellTextForTesting(section: section, row: row)
                XCTAssertEqual(text, expected,
                               "row \(section):\(row) must render \"\(expected)\", got \(text ?? "nil")")
            }
        }
    }

    /// Clicking a category shows the shortcuts pane sliced to it; General comes back.
    func testTheRailSwapsThePane() {
        let vc = hosted()
        XCTAssertTrue(vc.currentPaneForTesting === vc.generalForTesting)
        vc.selectRailForTesting(section: 1, row: 0)
        XCTAssertTrue(vc.currentPaneForTesting === vc.shortcutsForTesting)
        XCTAssertEqual(vc.shortcutsForTesting.selectedCategory, .yours)
        vc.selectRailForTesting(section: 0, row: 0)
        XCTAssertTrue(vc.currentPaneForTesting === vc.generalForTesting)
    }

    // MARK: - Row height must fit the row font

    /// The rail row height was once a hardcoded spec point, which clipped the
    /// labels wherever the row font grew past it.
    func testRailRowFitsItsLabel() {
        let font = NSFont.systemFont(ofSize: ChalkMetrics.sidebarRowFontSize)
        let lineHeight = font.ascender - font.descender + font.leading
        XCTAssertGreaterThanOrEqual(
            ChalkMetrics.settingsRailRowHeight, lineHeight + ChalkMetrics.s(10),
            "the row must clear the label's line height plus breathing room")
    }

    private func hosted() -> SettingsContainerViewController {
        let vc = SettingsContainerViewController()
        let window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 900, height: 660))
        window.rootViewController = vc
        window.isHidden = false
        vc.view.layoutSubtreeIfNeeded()
        vc.railViewForTesting.layoutSubtreeIfNeeded()
        windows.append(window)
        return vc
    }
}

// MARK: - Rail row geometry

/// On Catalyst the rail labels once rendered as a 2pt smear because the list
/// content kept its own default vertical margins. These assertions are on
/// real laid-out frames, because every content-level check passed while the
/// screen was unreadable.
@MainActor
final class SettingsRailGeometryTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { dismantleHostedSidebar(window) }
        windows = []
        super.tearDown()
    }

    private func laidOutRail() -> NSTableView {
        let vc = SettingsContainerViewController()
        let window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 900, height: 714))
        window.rootViewController = vc
        window.isHidden = false
        vc.view.layoutSubtreeIfNeeded()
        let table = vc.railViewForTesting
        table.layoutSubtreeIfNeeded()
        windows.append(window)
        return table
    }

    private func labels(in row: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        func walk(_ v: NSView) {
            for sub in v.subviews {
                if let label = sub as? NSTextField, !label.stringValue.isEmpty { found.append(label) }
                walk(sub)
            }
        }
        walk(row)
        return found
    }

    func testEveryRailLabelHasRoomForItsGlyphs() {
        let table = laidOutRail()
        var checked = 0
        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
            for label in labels(in: cell) {
                checked += 1
                let font = label.font ?? .systemFont(ofSize: 13)
                let needed = font.ascender - font.descender + font.leading
                XCTAssertGreaterThanOrEqual(
                    label.bounds.height, needed - 0.5,
                    "\"\(label.stringValue)\" has \(label.bounds.height)pt for a \(needed)pt line")
            }
        }
        XCTAssertGreaterThan(checked, 1, "the rail must actually have rows to check")
    }

    func testRailLabelsFitInsideTheirRow() {
        let table = laidOutRail()
        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
            for label in labels(in: cell) {
                let inCell = label.convert(label.bounds, to: cell)
                XCTAssertGreaterThanOrEqual(inCell.minY, -0.5, "label clipped at the top")
                XCTAssertLessThanOrEqual(inCell.maxY, cell.bounds.height + 0.5, "label clipped at the bottom")
            }
        }
    }

    /// The rail gives ground on a narrow container instead of eating a third
    /// of it; on a roomy one it keeps the spec width.
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
