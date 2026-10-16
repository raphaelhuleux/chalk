import XCTest
import ChalkKit
@testable import Chalk

/// The editor column's content geometry: the text spans the column, and its
/// top obeys the host's explicit band clearance and nothing else.
final class EditorColumnLayoutTests: XCTestCase {
    private var window: NSWindow!
    private var editor: EditorContainerViewController!

    override func setUp() {
        super.setUp()
        editor = EditorContainerViewController()
        window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
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

    func testContentTopFollowsTheBandClearance() {
        editor.setTopClearance(47)
        window.layoutIfNeeded()
        XCTAssertEqual(editor.contentViewFrameForTesting.minY, 47, accuracy: 0.5,
                       "content clears exactly the tab band")
    }

    func testContentKeepsFullWidth() {
        let frame = editor.contentViewFrameForTesting
        XCTAssertEqual(frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(frame.maxX, editor.view.bounds.maxX, accuracy: 0.5)
    }
}
