import XCTest
import ChalkKit
@testable import Chalk

/// Zoom and the default view mode are process-wide preferences that every new
/// tab reads. Changing either from one window must reach the tabs of every
/// window, or the other windows keep stale values and their new tabs mix both.
@MainActor
final class CrossWindowPreferenceTests: XCTestCase {
    private var incomingScale: Double!
    private var incomingViewMode: ViewMode!
    private var windows: [UIWindow] = []

    override func setUp() {
        super.setUp()
        // The real app's UserDefaults: snapshot here, restore in tearDown.
        incomingScale = Preferences.editorFontScale
        incomingViewMode = Preferences.viewMode
    }

    override func tearDown() {
        Preferences.editorFontScale = incomingScale
        Preferences.viewMode = incomingViewMode
        windows.forEach { $0.isHidden = true }
        windows = []
        super.tearDown()
    }

    /// A root in its own window of the host app's scene, so `everyLiveRoot()`
    /// sees it, with one open tab.
    private func hostedRoot() throws -> RootSplitViewController {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        let root = RootSplitViewController(initialContent: .openEmpty)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.isHidden = false
        windows.append(window)
        root.editor.newFile()
        return root
    }

    func testZoomReachesEveryWindow() throws {
        let here = try hostedRoot()
        let there = try hostedRoot()
        Preferences.editorFontScale = 1.0

        here.cmdZoomIn()

        let expected = Preferences.editorFontScale
        XCTAssertNotEqual(expected, 1.0)
        XCTAssertEqual(here.editor.tabSurfaceForTesting(at: 0)?.fontScaleForTesting, expected)
        XCTAssertEqual(there.editor.tabSurfaceForTesting(at: 0)?.fontScaleForTesting, expected,
                       "the other window kept the old zoom")
    }

    func testDefaultViewModeReachesEveryWindow() throws {
        let here = try hostedRoot()
        let there = try hostedRoot()
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
