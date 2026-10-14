import XCTest
import ChalkKit
@testable import Chalk

/// The `outline` push: transport-internal, decoded straight into the same
/// `OutlineSnapshot` the pull path uses, so the panel and the palette can
/// never disagree about the wire shape.
@MainActor
final class WebEditorSurfaceOutlinePushTests: XCTestCase {
    private func heading(_ title: String, level: Int, line: Int) -> OutlineItem {
        OutlineItem(kind: .heading, level: level, title: title, line: line,
                    calloutType: nil, number: nil)
    }

    func testOutlinePushDecodesIntoASnapshot() {
        let surface = WebEditorSurface()
        var received: [OutlineSnapshot] = []
        surface.onOutline = { received.append($0) }
        surface.handleHostMessage(body: [
            "type": "outline",
            "items": [["kind": "heading", "level": 2, "title": "Setup", "line": 4]],
            "cursorLine": 6,
        ] as [String: Any])
        XCTAssertEqual(received, [OutlineSnapshot(items: [heading("Setup", level: 2, line: 4)], cursorLine: 6)])
    }

    func testMalformedOutlinePushIsDropped() {
        let surface = WebEditorSurface()
        var count = 0
        surface.onOutline = { _ in count += 1 }
        surface.handleHostMessage(body: ["type": "outline", "items": "nope", "cursorLine": 1] as [String: Any])
        XCTAssertEqual(count, 0)
    }

    func testUnknownKindIsSkippedNotFatal() {
        let surface = WebEditorSurface()
        var received: [OutlineSnapshot] = []
        surface.onOutline = { received.append($0) }
        surface.handleHostMessage(body: [
            "type": "outline",
            "items": [
                ["kind": "hologram", "level": 0, "title": "?", "line": 1],
                ["kind": "heading", "level": 1, "title": "A", "line": 2],
            ],
            "cursorLine": 2,
        ] as [String: Any])
        XCTAssertEqual(received.first?.items, [heading("A", level: 1, line: 2)])
    }

    /// The subscription is remembered before `ready` and re-applied after a
    /// reload, like the chrome-top inset.
    func testSubscriptionIsRememberedBeforeReady() {
        let surface = WebEditorSurface()
        XCTAssertFalse(surface.isOutlineSubscribedForTesting)
        surface.setOutlineSubscription(true)
        XCTAssertTrue(surface.isOutlineSubscribedForTesting)
        surface.setOutlineSubscription(false)
        XCTAssertFalse(surface.isOutlineSubscribedForTesting)
    }
}
