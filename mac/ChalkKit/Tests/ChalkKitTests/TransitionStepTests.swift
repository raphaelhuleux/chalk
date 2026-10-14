import XCTest
@testable import ChalkKit

/// The product rules for chrome toggles, written down once: the transition
/// matrix asserts the shell against these, so a rule that lived only in the
/// shell would be a rule the tests merely echo.
final class TransitionStepTests: XCTestCase {
    private func state(sidebar: UIState.SidebarState = .shown,
                       window: UIState.WindowMode = .windowed,
                       outline: UIState.OutlineState = .hidden,
                       mode: UIState.ChromeMode = .normal) -> UIState {
        UIState(window: window, sidebar: sidebar,
                outline: outline, mode: mode, appearance: .light)
    }

    func testSidebarTogglesMoveOnlyTheSidebar() {
        XCTAssertEqual(state(sidebar: .shown).applying(.sidebar(false)),
                       state(sidebar: .hidden))
        XCTAssertEqual(state(sidebar: .hidden).applying(.sidebar(true)),
                       state(sidebar: .shown))
    }

    func testWindowTogglesMoveOnlyTheWindowMode() {
        XCTAssertEqual(state(window: .windowed).applying(.window(.fullscreen)),
                       state(window: .fullscreen))
        XCTAssertEqual(state(window: .fullscreen).applying(.window(.windowed)),
                       state(window: .windowed))
    }

    func testZenEntryForcesTheSidebarHidden() {
        XCTAssertEqual(state(sidebar: .shown).applying(.zen(true)),
                       state(sidebar: .hidden, mode: .zen),
                       "zen closes the Library whatever it was doing")
    }

    func testZenExitLeavesTheSidebarWhereZenLeftIt() {
        XCTAssertEqual(state(sidebar: .hidden, mode: .zen).applying(.zen(false)),
                       state(sidebar: .hidden, mode: .normal),
                       "leaving zen does not reopen the Library; the reader does")
    }

    func testOpeningTheSidebarInZenIsRefused() {
        let zen = state(sidebar: .hidden, mode: .zen)
        XCTAssertEqual(zen.applying(.sidebar(true)), zen,
                       "zen owns the chrome; panels do not open into it")
    }

    func testClosingTheSidebarInZenIsANoOpNotARefusal() {
        let zen = state(sidebar: .hidden, mode: .zen)
        XCTAssertEqual(zen.applying(.sidebar(false)), zen)
    }

    func testWindowToggleInZenKeepsZen() {
        XCTAssertEqual(state(sidebar: .hidden, mode: .zen).applying(.window(.fullscreen)),
                       state(sidebar: .hidden, window: .fullscreen, mode: .zen))
    }

    func testOutlineTogglesMoveOnlyTheOutline() {
        XCTAssertEqual(state(outline: .hidden).applying(.outline(true)),
                       state(outline: .shown))
        XCTAssertEqual(state(outline: .shown).applying(.outline(false)),
                       state(outline: .hidden))
    }

    func testZenEntryForcesTheOutlineHidden() {
        XCTAssertEqual(state(outline: .shown).applying(.zen(true)),
                       state(sidebar: .hidden, outline: .hidden, mode: .zen))
    }

    func testOutlineOpenInZenIsRefused() {
        let zen = state(sidebar: .hidden, outline: .hidden, mode: .zen)
        XCTAssertEqual(zen.applying(.outline(true)), zen)
    }

    func testZenExitLeavesTheOutlineWhereZenLeftIt() {
        XCTAssertEqual(state(sidebar: .hidden, outline: .hidden, mode: .zen).applying(.zen(false)),
                       state(sidebar: .hidden, outline: .hidden, mode: .normal))
    }
}
