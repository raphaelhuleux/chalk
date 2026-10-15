import XCTest
import ChalkKit
@testable import ChalkMac

/// Zoom and the default view mode are process-wide preferences that every new
/// tab reads. Changing either from one window must reach the tabs of every
/// window, or the other windows keep stale values and their new tabs mix both.
@MainActor
final class CrossWindowPreferenceTests: XCTestCase {
    private var incomingScale: Double!
    private var incomingViewMode: ViewMode!
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        // The real app's UserDefaults: snapshot here, restore in tearDown.
        incomingScale = Preferences.editorFontScale
        incomingViewMode = Preferences.viewMode
    }

    override func tearDown() {
        Preferences.editorFontScale = incomingScale
        Preferences.viewMode = incomingViewMode
        for window in windows { dismantleHostedSidebar(window) }
        windows = []
        super.tearDown()
    }

    /// A root in its own window, so `everyLiveRoot()` (which scans
    /// `NSApp.windows`) sees it, with one open tab.
    private func hostedRoot() -> RootSplitViewController {
        let root = RootSplitViewController(initialContent: .openEmpty)
        let window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1100, height: 760))
        window.rootViewController = root
        window.isHidden = false
        windows.append(window)
        root.editor.newFile()
        return root
    }

    func testZoomReachesEveryWindow() throws {
        let here = hostedRoot()
        let there = hostedRoot()
        XCTAssertTrue(RootSplitViewController.everyLiveRoot().contains { $0 === there },
                      "precondition: the hosted window is a live window")
        Preferences.editorFontScale = 1.0

        here.cmdZoomIn()

        let expected = Preferences.editorFontScale
        XCTAssertNotEqual(expected, 1.0)
        XCTAssertEqual(here.editor.tabSurfaceForTesting(at: 0)?.fontScaleForTesting, expected)
        XCTAssertEqual(there.editor.tabSurfaceForTesting(at: 0)?.fontScaleForTesting, expected,
                       "the other window kept the old zoom")
    }

    func testDefaultViewModeReachesEveryWindow() throws {
        let here = hostedRoot()
        let there = hostedRoot()
        Preferences.viewMode = .preview

        here.setViewModeDefault(.source)

        for root in [here, there] {
            guard case let .object(fields)? = root.editor.tabSurfaceForTesting(at: 0)?.editorConfigForTesting else {
                return XCTFail("no editor config reached the tab")
            }
            XCTAssertEqual(fields["viewMode"], .string("source"))
        }
    }
}
