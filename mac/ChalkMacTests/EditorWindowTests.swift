import AppKit
import XCTest
@testable import ChalkMac

/// The window contract plan decision 4 rests on: the content runs under a
/// transparent titlebar, so the band can own the title row's pixels, and an
/// empty unified toolbar gives that titlebar its tall form.
final class EditorWindowTests: XCTestCase {
    @MainActor
    func testWindowRunsUnderATransparentTitlebar() throws {
        let controller = EditorWindowController(initialContent: .openEmpty)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.contentMinSize, ChalkMetrics.minWindowSize)
        XCTAssertNotNil(window.toolbar, "the empty unified toolbar is what makes the titlebar tall")
        XCTAssertEqual(window.toolbar?.items.count, 0)
        XCTAssertTrue(window.contentViewController === controller.root)
    }

    @MainActor
    func testClosingTheWindowReportsToTheOwner() throws {
        let controller = EditorWindowController(initialContent: .openEmpty)
        var closed = false
        controller.onClose = { closed = true }
        controller.showWindow(nil)
        controller.close()
        XCTAssertTrue(closed)
    }
}
