import XCTest
import ChalkKit
@testable import Chalk

/// The macOS 27 Catalyst split view keeps the secondary column's view
/// FULL-SIZE and reports the sidebar-covered strip through the safe area
/// instead of moving the frame
/// (docs/issues/2026-09-17-macos-27-breaks-the-mac-chrome.md). The editor
/// content must therefore respect the HORIZONTAL safe area, or the Library
/// lands on top of the text. On older Catalyst the horizontal insets are zero,
/// so respecting them changes nothing there.
final class EditorSafeAreaTests: XCTestCase {
    private var window: UIWindow!
    private var editor: EditorContainerViewController!

    override func setUp() {
        super.setUp()
        editor = EditorContainerViewController()
        // Safe areas only resolve inside a window; host one in the test app's
        // live scene the way the split view hosts the real column.
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first!
        window = UIWindow(windowScene: scene)
        window.rootViewController = editor
        window.isHidden = false
        window.layoutIfNeeded()
    }

    override func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        editor = nil
        super.tearDown()
    }

    func testContentFollowsHorizontalSafeArea() {
        let before = editor.contentViewFrameForTesting

        // What the macOS 27 split view does when the Library tiles in: the
        // column keeps its frame and the safe area moves.
        editor.additionalSafeAreaInsets.left = 300
        window.layoutIfNeeded()

        let after = editor.contentViewFrameForTesting
        XCTAssertEqual(after.minX, before.minX + 300, accuracy: 0.5,
                       "the sidebar strip arrives as safe area; content must move out from under the glass")
        XCTAssertEqual(after.maxX, before.maxX, accuracy: 0.5,
                       "only the leading edge moves; the trailing edge stays put")
    }

    func testContentTopFollowsBandClearanceNotSafeArea() {
        // A top safe area (the titlebar, or a reserved nav-bar strip we don't
        // use) must not move the content: its top obeys the host's explicit
        // band clearance and ignores the safe area.
        editor.additionalSafeAreaInsets.top = 86
        editor.setTopClearance(47)
        window.layoutIfNeeded()
        XCTAssertEqual(editor.contentViewFrameForTesting.minY, 47, accuracy: 0.5,
                       "content clears exactly the tab band; the safe-area top adds nothing")
    }

    func testContentKeepsFullWidthWithoutHorizontalInsets() {
        let frame = editor.contentViewFrameForTesting
        XCTAssertEqual(frame.minX, editor.view.safeAreaInsets.left, accuracy: 0.5)
        XCTAssertEqual(frame.maxX, editor.view.bounds.maxX - editor.view.safeAreaInsets.right,
                       accuracy: 0.5)
    }
}
