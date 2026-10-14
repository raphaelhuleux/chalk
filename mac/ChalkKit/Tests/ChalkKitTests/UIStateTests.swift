import XCTest
@testable import ChalkKit

final class UIStateTests: XCTestCase {
    func testMatrixIsTheFullCrossProduct() {
        // 2 window modes x 2 sidebar x 2 outline x 2 chrome modes x 2 appearances
        XCTAssertEqual(UIState.matrix.count, 32)
        XCTAssertEqual(Set(UIState.matrix.map(\.id)).count, 32, "ids must be unique")
    }

    func testIdRoundTrips() {
        for state in UIState.matrix {
            XCTAssertEqual(UIState(id: state.id), state, "\(state.id) did not round-trip")
        }
    }

    func testIdIsStableAndReadable() {
        let state = UIState(window: .windowed, sidebar: .shown,
                            outline: .hidden, mode: .zen, appearance: .dark)
        XCTAssertEqual(state.id, "windowed-sidebar-nooutline-zen-dark")
        let open = UIState(window: .fullscreen, sidebar: .hidden,
                           outline: .shown, mode: .normal, appearance: .light)
        XCTAssertEqual(open.id, "fullscreen-nosidebar-outline-normal-light")
    }

    func testUnknownIdIsRejected() {
        XCTAssertNil(UIState(id: "windowed-sidebar-nooutline-zen"))       // too few parts
        XCTAssertNil(UIState(id: "tiled-sidebar-nooutline-zen-dark"))     // unknown window mode
    }

    func testMalformedHyphenationIsRejected() {
        // A leading, trailing, or doubled hyphen must not collapse away into
        // 5 clean parts and silently resolve to a different valid state.
        XCTAssertNil(UIState(id: "-windowed-sidebar-nooutline-zen-dark"))  // leading hyphen
        XCTAssertNil(UIState(id: "windowed--sidebar-nooutline-zen-dark"))  // doubled hyphen
        XCTAssertNil(UIState(id: "windowed-sidebar-nooutline-zen-dark-"))  // trailing hyphen
    }

    func testOutlineDefaultsToHidden() {
        let state = UIState(window: .windowed, sidebar: .shown,
                            mode: .normal, appearance: .light)
        XCTAssertEqual(state.outline, .hidden)
    }

    /// The pre-outline four-part form and the six-part form that led with a
    /// platform must not parse as some other state.
    func testIdsOfOtherLengthsAreRejected() {
        XCTAssertNil(UIState(id: "windowed-sidebar-zen-dark"))
        XCTAssertNil(UIState(id: "mac-windowed-sidebar-nooutline-zen-dark"))
    }
}
