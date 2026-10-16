import XCTest
@testable import ChalkKit

final class UIStateTests: XCTestCase {
    func testMatrixIsTheFullCrossProduct() {
        // 2 window modes x 2 sidebar x 2 outline x 2 chrome modes x 2 appearances
        XCTAssertEqual(UIState.matrix.count, 32)
        XCTAssertEqual(Set(UIState.matrix.map(\.id)).count, 32, "ids must be unique")
    }

    func testIdIsStableAndReadable() {
        let state = UIState(window: .windowed, sidebar: .shown,
                            outline: .hidden, mode: .zen, appearance: .dark)
        XCTAssertEqual(state.id, "windowed-sidebar-nooutline-zen-dark")
        let open = UIState(window: .fullscreen, sidebar: .hidden,
                           outline: .shown, mode: .normal, appearance: .light)
        XCTAssertEqual(open.id, "fullscreen-nosidebar-outline-normal-light")
    }

    func testOutlineDefaultsToHidden() {
        let state = UIState(window: .windowed, sidebar: .shown,
                            mode: .normal, appearance: .light)
        XCTAssertEqual(state.outline, .hidden)
    }
}
