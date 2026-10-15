import XCTest
import ChalkKit
@testable import Chalk

/// docs/motion.md "Tab switch" (C2): switching tabs cross-fades the two
/// surface views over `motionFast` with BOTH hosted for the duration, the
/// outgoing view leaves only after the fade, and the incoming surface
/// receives the current appearance and chrome-top BEFORE it can become
/// visible (before install).
@MainActor
final class TabSwitchContractTests: XCTestCase {
    private var window: UIWindow!
    private var editor: EditorContainerViewController!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else {
            preconditionFailure("no scene to host in")
        }
        // Window-hosted: the cross-fade's animated lane only runs for views
        // that can appear on screen; unhosted it takes the instant branch.
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        window.isHidden = false
        editor = EditorContainerViewController()
        window.rootViewController = editor
        editor.loadViewIfNeeded()
        window.layoutIfNeeded()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-tabswitch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        editor = nil
        super.tearDown()
    }

    private func open(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
        editor.open(url: url)
        return url
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func testSwitchKeepsBothSurfacesHostedThenExactlyOne() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled,
                      "Reduce Motion takes the instant swap; the fade contract is about the animated lane")
        let a = try open("a.md")
        let first = try XCTUnwrap(editor.activeSurfaceWebView)
        _ = try open("b.md")
        let second = try XCTUnwrap(editor.activeSurfaceWebView)
        XCTAssertNotEqual(first, second, "two tabs, two surfaces")

        // Mid-fade (b just activated): both hosted, incoming on top.
        XCTAssertNotNil(first.superview, "the outgoing surface stays hosted through the fade")
        XCTAssertNotNil(second.superview, "the incoming surface is hosted from t=0")

        pump(ChalkMetrics.motionFast + 0.2)
        XCTAssertNil(first.superview, "the outgoing surface leaves after the fade")
        XCTAssertNotNil(second.superview)
        XCTAssertEqual(second.alpha, 1, accuracy: 0.01)

        // Switch back: same contract in the other direction.
        editor.open(url: a)
        XCTAssertNotNil(first.superview ?? second.superview)
        XCTAssertNotNil(editor.activeSurfaceWebView?.superview)
        XCTAssertNotNil(second.superview, "outgoing (b) stays through the fade")
        pump(ChalkMetrics.motionFast + 0.2)
        XCTAssertNil(second.superview, "exactly one surface hosted at rest")
        XCTAssertEqual(first.alpha, 1, accuracy: 0.01,
                       "a surface re-hosted after fading out must come back fully opaque")
    }

    func testIncomingSurfaceIsDressedBeforeInstall() throws {
        // A bare container has no chrome-top yet; give it the host's push so
        // the ordering under test involves a real inset.
        editor.setChromeTopInset(64)
        _ = try open("a.md")
        editor.activateEventTrailForTesting.removeAll()
        _ = try open("b.md")

        let trail = editor.activateEventTrailForTesting
        guard let install = trail.firstIndex(of: "install") else {
            return XCTFail("activation must install the incoming surface; trail=\(trail)")
        }
        guard let appearance = trail.firstIndex(of: "appearance"),
              let chromeTop = trail.firstIndex(of: "chrome-top") else {
            return XCTFail("activation must push appearance and chrome-top; trail=\(trail)")
        }
        XCTAssertLessThan(appearance, install,
                          "appearance lands BEFORE the surface can become visible; trail=\(trail)")
        XCTAssertLessThan(chromeTop, install,
                          "chrome-top lands BEFORE the surface can become visible; trail=\(trail)")
    }

    func testRapidSwitchNeverRemovesTheActiveSurface() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        let a = try open("a.md")
        let first = try XCTUnwrap(editor.activeSurfaceWebView)
        _ = try open("b.md")
        // Mid-fade, come straight back to a: the completion of the a->b fade
        // must not remove a's view — it is the active surface again.
        editor.open(url: a)
        pump(ChalkMetrics.motionFast + 0.3)
        XCTAssertNotNil(first.superview,
                        "a surface re-activated mid-fade must survive the stale fade's completion")
        XCTAssertEqual(first.alpha, 1, accuracy: 0.01)
        XCTAssertEqual(editor.activeSurfaceWebView, first)
    }
}
