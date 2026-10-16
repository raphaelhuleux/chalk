import XCTest
@testable import ChalkKit

final class UIStateTests: XCTestCase {
    func testMatrixIsTheFullCrossProduct() {
        // 2 window modes x 2 sidebar x 3 trailing slot x 2 chrome modes x 2 appearances
        XCTAssertEqual(UIState.matrix.count, 48)
        XCTAssertEqual(Set(UIState.matrix.map(\.id)).count, 48, "ids must be unique")
    }

    func testIdIsStableAndReadable() {
        let state = UIState(window: .windowed, sidebar: .shown,
                            outline: .hidden, mode: .zen, appearance: .dark)
        XCTAssertEqual(state.id, "windowed-sidebar-nooutline-zen-dark")
        let open = UIState(window: .fullscreen, sidebar: .hidden,
                           outline: .shown, mode: .normal, appearance: .light)
        XCTAssertEqual(open.id, "fullscreen-nosidebar-outline-normal-light")
        let pdf = UIState(window: .windowed, sidebar: .hidden,
                          outline: .pdf, mode: .normal, appearance: .dark)
        XCTAssertEqual(pdf.id, "windowed-nosidebar-pdf-normal-dark")
    }

    func testOutlineDefaultsToHidden() {
        let state = UIState(window: .windowed, sidebar: .shown,
                            mode: .normal, appearance: .light)
        XCTAssertEqual(state.outline, .hidden)
    }
}
