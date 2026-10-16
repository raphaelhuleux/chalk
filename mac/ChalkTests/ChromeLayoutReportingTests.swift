import XCTest
import ChalkKit
@testable import Chalk

/// The reported layout must describe the REAL views. A layout assembled from
/// constants would make every invariant in Task 4 a tautology.
@MainActor
final class ChromeLayoutReportingTests: XCTestCase {
    private func loadedRoot() -> RootSplitViewController {
        let root = RootSplitViewController()
        root.loadViewIfNeeded()
        root.view.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        root.view.layoutIfNeeded()
        return root
    }

    private var anyState: UIState {
        UIState(window: .fullscreen, sidebar: .hidden,
                mode: .normal, appearance: .dark)
    }

    func testLayoutReportsTheRealRootBounds() {
        let root = loadedRoot()
        XCTAssertEqual(root.chromeLayout(for: anyState).root, root.view.bounds)
    }

    func testLayoutReportsTheRealBandFrame() throws {
        let root = loadedRoot()
        let layout = root.chromeLayout(for: anyState)
        XCTAssertEqual(layout.band.height, root.headerBandHeightForTesting, accuracy: 0.5,
                       "the band rect must come from the live band, not a constant")
        XCTAssertGreaterThan(layout.band.width, 0)
    }

    func testLayoutReportsTheRestingLineTheEditorWasActuallyGiven() throws {
        let root = loadedRoot()
        let layout = root.chromeLayout(for: anyState)
        // Not `x ?? 0` against `x ?? -1` of the same source, which is what this
        // was: a tautology that also warned, and warnings are errors here.
        // The claim worth making is that the layout reports the value the
        // editor was actually handed, and that the value is real.
        let given = try XCTUnwrap(root.editorChromeTopInsetForTesting,
                                  "the editor was never given a chrome inset")
        XCTAssertEqual(layout.editorRestingTop, CGFloat(given), accuracy: 0.5)
        XCTAssertGreaterThan(given, 0, "a zero inset would make the comparison vacuous")
    }

    func testLibraryPanelIsNilWhenTheSidebarIsHidden() {
        let root = loadedRoot()
        root.setSidebarVisible(false)
        root.view.layoutIfNeeded()
        XCTAssertNil(root.chromeLayout(for: anyState).libraryPanel)
    }
}
