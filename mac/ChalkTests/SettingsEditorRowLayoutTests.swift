import XCTest
import ChalkKit
@testable import Chalk

/// The Editor rows put controls at the trailing edge, where an NSSlider is a
/// trap: it has no intrinsic width, so without an explicit one it lays out
/// at zero width and the row renders as a label with nothing next to it.
/// These assert on real laid-out frames; a title-only check passes happily
/// while the control is invisible.
@MainActor
final class SettingsEditorRowLayoutTests: XCTestCase {
    /// A realistic settings-window row width.
    private let rowWidth: CGFloat = 520

    private func laidOutRow(_ row: Int) -> SettingsRowView {
        let vc = GeneralSettingsViewController()
        vc.loadViewIfNeeded()
        let view = vc.editorRowForTesting(row)
        view.frame = CGRect(x: 0, y: 0, width: rowWidth, height: SettingsRowView.height)
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testSliderRowsGiveTheirControlRealWidth() throws {
        for row in [0, 1, 2] {
            let view = laidOutRow(row)
            let control = try XCTUnwrap(view.control)
            XCTAssertTrue(control is NSSlider, "row \(row) should carry a slider")
            XCTAssertGreaterThan(control.frame.width, 100,
                                 "a slider with no explicit width collapses to zero")
            XCTAssertGreaterThan(control.frame.height, 0)
        }
    }

    func testSegmentedRowsCarryEverySegment() throws {
        let alignment = try XCTUnwrap(laidOutRow(3).control as? NSSegmentedControl)
        XCTAssertEqual(alignment.segmentCount, EditorTextAlignment.allCases.count)
        XCTAssertEqual(alignment.label(forSegment: 0), "Left")
        XCTAssertEqual(alignment.label(forSegment: 1), "Justified")

        let fileType = try XCTUnwrap(laidOutRow(5).control as? NSSegmentedControl)
        XCTAssertEqual(fileType.segmentCount, DefaultFileType.allCases.count)
        XCTAssertEqual(fileType.label(forSegment: 0), "Markdown")
        XCTAssertEqual(fileType.label(forSegment: 1), "LaTeX")

        let viewMode = try XCTUnwrap(laidOutRow(6).control as? NSSegmentedControl)
        XCTAssertEqual(viewMode.segmentCount, ViewMode.allCases.count)
        XCTAssertEqual(viewMode.label(forSegment: 0), "Preview")
        XCTAssertEqual(viewMode.label(forSegment: 1), "Mixed")
        XCTAssertEqual(viewMode.label(forSegment: 2), "Source")
    }

    /// Label, readout and control must all fit side by side without the
    /// control running off the row or sitting on top of the title.
    func testControlsFitBesideTheirLabels() throws {
        for row in 0..<7 {
            let view = laidOutRow(row)
            let control = try XCTUnwrap(view.control)
            XCTAssertLessThanOrEqual(control.frame.maxX, rowWidth,
                                     "row \(row): control runs past the row's edge")
            XCTAssertGreaterThanOrEqual(control.frame.minX, view.titleLabel.frame.maxX,
                                        "row \(row): control overlaps its own label")
            XCTAssertLessThanOrEqual(view.detailLabel.frame.maxX, control.frame.minX + 0.5,
                                     "row \(row): readout overlaps the control")
        }
    }

    /// The switch row sits between the segmented rows, so the sliders-are-0-1-2
    /// and segments-are-3-5-6 layout above only holds if it really is a
    /// switch at 4.
    func testTheHeadingColorRowCarriesASwitch() {
        XCTAssertNotNil(laidOutRow(4).control as? NSSwitch)
    }

    /// The readout is what makes a slider legible; an empty one is a bug the
    /// title-inventory test cannot see.
    func testSliderRowsShowAReadout() {
        XCTAssertEqual(laidOutRow(0).detailLabel.stringValue,
                       "\(Int((Preferences.editorFontScale * 100).rounded()))%")
        XCTAssertEqual(laidOutRow(1).detailLabel.stringValue,
                       "\(Int(Preferences.editorMeasure.rounded())) px")
        XCTAssertEqual(laidOutRow(2).detailLabel.stringValue,
                       String(format: "%.2fx", Preferences.editorLineHeight))
    }
}
