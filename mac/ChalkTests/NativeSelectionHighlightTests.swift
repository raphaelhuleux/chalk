import XCTest
import UIKit
@testable import Chalk

/// Only the editor's own selection may paint.
///
/// WebKit's native selection highlight sat above the page as a 20% black film
/// that missed CodeMirror's selection by up to a row (see
/// NativeSelectionHighlight). These pin that the surface's web view ends up
/// with an inert highlight view, on the real WebKit structure: if a WebKit
/// update stops exposing its `UITextSelectionDisplayInteraction` on the view
/// tree, the second test fails instead of the film quietly coming back.
@MainActor
final class NativeSelectionHighlightTests: XCTestCase {
    private final class DisplayDelegate: NSObject, UITextSelectionDisplayInteractionDelegate {}

    private func displayInteractions(in root: UIView) -> [UITextSelectionDisplayInteraction] {
        var found: [UITextSelectionDisplayInteraction] = []
        var stack = [root]
        while let view = stack.popLast() {
            found += view.interactions.compactMap { $0 as? UITextSelectionDisplayInteraction }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    func testReplacesEveryHighlightInTheSubtreeOnce() {
        let root = UIView()
        let nested = UIView()
        root.addSubview(UIView())
        root.subviews[0].addSubview(nested)
        let delegate = DisplayDelegate()
        let display = UITextSelectionDisplayInteraction(textInput: UITextView(), delegate: delegate)
        nested.addInteraction(display)

        XCTAssertEqual(NativeSelectionHighlight.suppress(in: root), 1)
        XCTAssertTrue(display.highlightView is InertSelectionHighlightView)
        XCTAssertEqual(NativeSelectionHighlight.suppress(in: root), 0, "a second pass must be a no-op")
    }

    func testEditorWebViewInAWindowPaintsNoNativeHighlight() throws {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("no connected UIWindowScene to host the web view in")
        }
        let window = UIWindow(windowScene: scene)
        window.isHidden = false
        defer { window.isHidden = true }
        let surface = WebEditorSurface()
        surface.view.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.addSubview(surface.view)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        let displays = displayInteractions(in: surface.view)
        XCTAssertFalse(
            displays.isEmpty,
            "WebKit no longer hangs a UITextSelectionDisplayInteraction on the web view's subtree")
        for display in displays {
            XCTAssertTrue(
                display.highlightView is InertSelectionHighlightView,
                "native highlight still paints: \(type(of: display.highlightView))")
        }
        surface.view.removeFromSuperview()
    }
}
