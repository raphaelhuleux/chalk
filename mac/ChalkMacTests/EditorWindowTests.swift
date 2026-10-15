import AppKit
import XCTest
@testable import ChalkMac

/// The window contract plan decision 4 rests on: the content runs under a
/// transparent titlebar, so the strip can own the title row's pixels.
final class EditorWindowTests: XCTestCase {
    @MainActor
    func testWindowRunsUnderATransparentTitlebar() throws {
        let controller = EditorWindowController()
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.minSize, EditorWindowController.minimumSize)
    }

    @MainActor
    func testClosingTheWindowReportsToTheOwner() throws {
        let controller = EditorWindowController()
        var closed = false
        controller.onClose = { closed = true }
        controller.showWindow(nil)
        controller.close()
        XCTAssertTrue(closed)
    }
}
