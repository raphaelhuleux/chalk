import XCTest
import ChalkKit
@testable import Chalk

/// The Editor rows put controls in `accessoryView`, where a UISlider is a trap:
/// it has no intrinsic content size, so without an explicit frame it lays out
/// at zero width and the row renders as a label with nothing next to it. These
/// assert on real laid-out frames (the SettingsRailGeometryTests approach) —
/// a title-only check passes happily while the control is invisible.
@MainActor
final class SettingsEditorRowLayoutTests: XCTestCase {
    /// A realistic settings-sheet row width.
    private let rowWidth: CGFloat = 520

    private func laidOutCell(row: Int) -> UITableViewCell {
        let vc = GeneralSettingsViewController()
        vc.loadViewIfNeeded()
        let table = vc.view.subviews.compactMap { $0 as? UITableView }.first!
        let cell = vc.tableView(table, cellForRowAt: IndexPath(row: row, section: 1))
        cell.frame = CGRect(x: 0, y: 0, width: rowWidth, height: 44)
        cell.layoutIfNeeded()
        return cell
    }

    func testSliderRowsGiveTheirControlRealWidth() {
        for row in [0, 1, 2] {
            let cell = laidOutCell(row: row)
            let accessory = try! XCTUnwrap(cell.accessoryView)
            XCTAssertTrue(accessory is UISlider, "row \(row) should carry a slider")
            XCTAssertGreaterThan(accessory.frame.width, 100,
                                 "a slider with no explicit frame collapses to zero width")
            XCTAssertGreaterThan(accessory.frame.height, 0)
        }
    }

    func testSegmentedRowsCarryEverySegment() {
        let alignment = try! XCTUnwrap(laidOutCell(row: 3).accessoryView as? UISegmentedControl)
        XCTAssertEqual(alignment.numberOfSegments, EditorTextAlignment.allCases.count)
        XCTAssertEqual(alignment.titleForSegment(at: 0), "Left")
        XCTAssertEqual(alignment.titleForSegment(at: 1), "Justified")

        let fileType = try! XCTUnwrap(laidOutCell(row: 5).accessoryView as? UISegmentedControl)
        XCTAssertEqual(fileType.numberOfSegments, DefaultFileType.allCases.count)
        XCTAssertEqual(fileType.titleForSegment(at: 0), "Markdown")
        XCTAssertEqual(fileType.titleForSegment(at: 1), "LaTeX")

        let viewMode = try! XCTUnwrap(laidOutCell(row: 6).accessoryView as? UISegmentedControl)
        XCTAssertEqual(viewMode.numberOfSegments, ViewMode.allCases.count)
        XCTAssertEqual(viewMode.titleForSegment(at: 0), "Preview")
        XCTAssertEqual(viewMode.titleForSegment(at: 1), "Mixed")
        XCTAssertEqual(viewMode.titleForSegment(at: 2), "Source")
    }

    /// Label, readout and control must all fit side by side without the
    /// accessory running off the row or sitting on top of the title.
    func testControlsFitBesideTheirLabels() {
        for row in 0..<6 {
            let cell = laidOutCell(row: row)
            let accessory = try! XCTUnwrap(cell.accessoryView)
            let title = try! XCTUnwrap(cell.textLabel)
            XCTAssertLessThanOrEqual(accessory.frame.maxX, rowWidth,
                                     "row \(row): control runs past the row's edge")
            XCTAssertGreaterThanOrEqual(accessory.frame.minX, title.frame.maxX,
                                        "row \(row): control overlaps its own label")
        }
    }

    /// The switch row sits between the segmented rows, so the sliders-are-0-1-2
    /// and segments-are-3-and-5 layout above only holds if it really is a
    /// UISwitch at 4.
    func testTheHeadingColorRowCarriesASwitch() {
        XCTAssertNotNil(laidOutCell(row: 4).accessoryView as? UISwitch)
    }

    /// The readout is what makes a slider legible; an empty one is a bug the
    /// title-inventory test cannot see.
    func testSliderRowsShowAReadout() {
        XCTAssertEqual(laidOutCell(row: 0).detailTextLabel?.text,
                       "\(Int((Preferences.editorFontScale * 100).rounded()))%")
        XCTAssertEqual(laidOutCell(row: 1).detailTextLabel?.text,
                       "\(Int(Preferences.editorMeasure.rounded())) px")
        XCTAssertEqual(laidOutCell(row: 2).detailTextLabel?.text,
                       String(format: "%.2fx", Preferences.editorLineHeight))
    }
}
