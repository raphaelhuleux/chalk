import XCTest
@testable import ChalkKit

final class UIStateTests: XCTestCase {
    func testMatrixIsTheFullCrossProduct() {
        // 2 window modes x 2 sidebar x 4 trailing slot x 2 chrome modes x 2 group layouts x 2 appearances
        XCTAssertEqual(UIState.matrix.count, 128)
        XCTAssertEqual(Set(UIState.matrix.map(\.id)).count, 128, "ids must be unique")
    }

    func testIdIsStableAndReadable() {
        let state = UIState(window: .windowed, sidebar: .shown,
                            outline: .hidden, mode: .zen, appearance: .dark)
        XCTAssertEqual(state.id, "windowed-sidebar-nooutline-zen-single-dark")
        let open = UIState(window: .fullscreen, sidebar: .hidden,
                           outline: .shown, mode: .normal, appearance: .light)
        XCTAssertEqual(open.id, "fullscreen-nosidebar-outline-normal-single-light")
        let pdf = UIState(window: .windowed, sidebar: .hidden,
                          outline: .pdf, mode: .normal, groups: .multiple, appearance: .dark)
        XCTAssertEqual(pdf.id, "windowed-nosidebar-pdf-normal-groups-dark")
    }

    func testOutlineDefaultsToHidden() {
        let state = UIState(window: .windowed, sidebar: .shown,
                            mode: .normal, appearance: .light)
        XCTAssertEqual(state.outline, .hidden)
    }

    func testSplitDefaultsToSingle() {
        let state = UIState(window: .windowed, sidebar: .shown,
                            mode: .normal, appearance: .light)
        XCTAssertEqual(state.groups, .single)
    }

    func testAppearanceIsTheLastIdComponent() {
        // The matrix test's light/dark sibling key drops the final component.
        for state in UIState.matrix {
            XCTAssertEqual(state.id.split(separator: "-").last.map(String.init), state.appearance.rawValue)
        }
    }

    func testZenKeepsTheSplit() {
        let split = UIState(window: .windowed, sidebar: .shown, outline: .shown,
                            mode: .normal, groups: .multiple, appearance: .light)
        let zen = split.applying(.zen(true))
        XCTAssertEqual(zen.groups, .multiple)
        XCTAssertEqual(zen.applying(.zen(false)).groups, .multiple)
        XCTAssertEqual(split.applying(.groups(false)).groups, .single)
        XCTAssertEqual(split.applying(.groups(false)).outline, .shown)
    }
}
