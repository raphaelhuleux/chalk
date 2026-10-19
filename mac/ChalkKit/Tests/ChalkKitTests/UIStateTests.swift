import XCTest
@testable import ChalkKit

final class UIStateTests: XCTestCase {
    func testMatrixIsTheFullCrossProduct() {
        // 2 window modes x 2 sidebar x 3 trailing slot x 2 chrome modes x 2 splits x 2 appearances
        XCTAssertEqual(UIState.matrix.count, 96)
        XCTAssertEqual(Set(UIState.matrix.map(\.id)).count, 96, "ids must be unique")
    }

    func testIdIsStableAndReadable() {
        let state = UIState(window: .windowed, sidebar: .shown,
                            outline: .hidden, mode: .zen, appearance: .dark)
        XCTAssertEqual(state.id, "windowed-sidebar-nooutline-zen-single-dark")
        let open = UIState(window: .fullscreen, sidebar: .hidden,
                           outline: .shown, mode: .normal, appearance: .light)
        XCTAssertEqual(open.id, "fullscreen-nosidebar-outline-normal-single-light")
        let pdf = UIState(window: .windowed, sidebar: .hidden,
                          outline: .pdf, mode: .normal, split: .split, appearance: .dark)
        XCTAssertEqual(pdf.id, "windowed-nosidebar-pdf-normal-split-dark")
    }

    func testOutlineDefaultsToHidden() {
        let state = UIState(window: .windowed, sidebar: .shown,
                            mode: .normal, appearance: .light)
        XCTAssertEqual(state.outline, .hidden)
    }

    func testSplitDefaultsToSingle() {
        let state = UIState(window: .windowed, sidebar: .shown,
                            mode: .normal, appearance: .light)
        XCTAssertEqual(state.split, .single)
    }

    func testAppearanceIsTheLastIdComponent() {
        // The matrix test's light/dark sibling key drops the final component.
        for state in UIState.matrix {
            XCTAssertEqual(state.id.split(separator: "-").last.map(String.init), state.appearance.rawValue)
        }
    }

    func testZenKeepsTheSplit() {
        let split = UIState(window: .windowed, sidebar: .shown, outline: .shown,
                            mode: .normal, split: .split, appearance: .light)
        let zen = split.applying(.zen(true))
        XCTAssertEqual(zen.split, .split)
        XCTAssertEqual(zen.applying(.zen(false)).split, .split)
        XCTAssertEqual(split.applying(.split(false)).split, .single)
        XCTAssertEqual(split.applying(.split(false)).outline, .shown)
    }
}
