import XCTest
import ChalkKit
@testable import Chalk

/// A scene that owns no NSWindow number addresses no titlebar strip, and
/// binding replays every decision it took while it had nowhere to send them.
///
/// The four glue posts that carry strip STATE (`leadingInset`, `setVisible`,
/// `setFaded`, `setScrimmed`) are routed by windowNumber, and the glue falls
/// back to the key/main window for a post that carries none. Three of the four
/// used to send anyway while unbound, with the number simply left out of the
/// payload — so a background scene's zen, auto-hide or palette decision landed
/// on whichever strip happened to be key. That is the same class of bug as the
/// untagged tab-update broadcast U8 fixed (R1/R2), one layer over.
///
/// The DECISION is still recorded while unbound (the strip invariants read
/// those recordings, and the bind replay re-sends them), which is what makes
/// "record but do not post" the thing to assert rather than "do nothing".
///
/// This replaces the NotificationCenter-observing version of the same rule
/// (`UnboundStripPostTests`, retired 2026-09-10). That test had to count only
/// UNTAGGED posts, because the real scene root shares this process and this
/// notification center; driving `MacStripBridge` through its injected `poster`
/// sees exactly this bridge's traffic and nothing else, so the assertions can
/// be about the whole payload instead of about the absence of a key.
///
/// The bridge under test can never be captured by the real glue's bind
/// traffic: its host reports no window and it publishes no token, so
/// `WindowRouting.bindTarget` returns nil for every post that passes by.
@MainActor
final class MacStripBridgeTests: XCTestCase {
    /// A window number no live NSWindow will be using.
    private let boundNumber = 987_654_321

    private final class StubHost: MacStripBridgeHost {
        var stripBridgeWindow: UIWindow? { nil }
        var stripBridgeWindowIsKey = false
        var stripBridgeScrimmed = false
        private(set) var insetPushes = 0
        private(set) var establishedWindows = 0
        func stripBridgePushLeadingInset() { insetPushes += 1 }
        func stripBridgeDidEstablishWindow() { establishedWindows += 1 }
        func stripBridgeApplyFullScreen(_ on: Bool) {}
        func stripBridgePerform(_ action: MacStripBridge.StripAction) {}
    }

    private final class Recorder {
        private(set) var posts: [(name: Notification.Name, info: [String: Any])] = []
        var names: [Notification.Name] { posts.map(\.name) }
        func info(for name: Notification.Name) -> [String: Any]? {
            posts.first { $0.name == name }?.info
        }
        var poster: MacStripBridge.Poster {
            { [weak self] name, info in self?.posts.append((name, info)) }
        }
    }

    func testAnUnboundBridgeRecordsItsDecisionsAndAddressesNoStrip() {
        let host = StubHost()
        let recorder = Recorder()
        let bridge = MacStripBridge(host: host, poster: recorder.poster)

        // A palette up, zen's fade, a visibility change, and a sidebar slide:
        // every state decision a scene can take before its window exists.
        host.stripBridgeScrimmed = true
        bridge.sendScrim()
        bridge.postFaded(true, over: 0.2)
        bridge.postVisibility(false)
        bridge.postLeadingInset(dividerX: 240, outlineWidth: 30, slideDuration: nil)

        XCTAssertEqual(recorder.names, [],
                       "an unbound scene must address no strip at all — an "
                       + "untagged post is delivered to whichever strip is key")
        XCTAssertTrue(bridge.lastFaded, "the fade decision is still RECORDED")
        XCTAssertFalse(bridge.lastVisible, "the hide decision is still RECORDED")
        XCTAssertEqual(bridge.lastDividerX, 240, accuracy: 0.001)
    }

    func testBindReplaysTheRecordedFadeHideAndScrimTaggedWithTheBoundNumber() {
        let host = StubHost()
        let recorder = Recorder()
        let bridge = MacStripBridge(host: host, poster: recorder.poster)

        host.stripBridgeScrimmed = true
        bridge.postFaded(true, over: 0.2)
        bridge.postVisibility(false)
        XCTAssertEqual(recorder.names, [], "precondition: nothing posted while unbound")

        bridge.bind(to: boundNumber)

        // The full snapshot first (the bind→push invariant), then the replay.
        XCTAssertEqual(recorder.names,
                       [TabStripBridge.update, TabStripBridge.setFaded,
                        TabStripBridge.setVisible, TabStripBridge.setScrimmed])
        XCTAssertEqual(host.insetPushes, 1,
                       "binding re-measures and re-posts the divider inset")
        XCTAssertEqual(host.establishedWindows, 1,
                       "binding is the earliest moment the window's NSAppearance can be set")

        for name in recorder.names {
            XCTAssertEqual(recorder.info(for: name)?[TabStripBridge.windowNumberKey] as? Int,
                           boundNumber,
                           "\(name.rawValue) must name the window it belongs to (U6)")
        }
        let faded = recorder.info(for: TabStripBridge.setFaded)
        XCTAssertEqual(faded?[TabStripBridge.fadedKey] as? Bool, true)
        XCTAssertEqual(faded?[TabStripBridge.durationKey] as? TimeInterval, 0,
                       "a state replay is restoration, not motion")
        XCTAssertEqual(recorder.info(for: TabStripBridge.setVisible)?[TabStripBridge.visibleKey] as? Bool,
                       false)
        XCTAssertEqual(recorder.info(for: TabStripBridge.setScrimmed)?[TabStripBridge.scrimmedKey] as? Bool,
                       true)
    }

    /// Visibility replays in the HIDE direction only: posting `true` would
    /// un-hide a toolbar full screen deliberately hid, and the glue already
    /// shows the strip at attach.
    func testTheReplayNeverPostsVisibilityInTheShowDirection() {
        let host = StubHost()
        let recorder = Recorder()
        let bridge = MacStripBridge(host: host, poster: recorder.poster)
        XCTAssertTrue(bridge.lastVisible, "precondition: the strip's seed is shown")

        bridge.bind(to: boundNumber + 1)

        XCTAssertEqual(recorder.names,
                       [TabStripBridge.update, TabStripBridge.setFaded,
                        TabStripBridge.setScrimmed])
    }
}
