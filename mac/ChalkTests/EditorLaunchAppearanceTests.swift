import XCTest
@testable import Chalk

/// The launch document must come up in the app's theme.
///
/// The host opens it inside its own `viewDidLoad`, where this container has no
/// window and its trait reads `.unspecified` — so `activate` stores light
/// while the native chrome goes dark, and the page shows cream paper under a
/// dark band. The host's launch push cannot cover it either: it fires one line
/// before the document opens, when there is no tab to receive it. C4 silenced
/// the container's trait hook (the covered transition owns the flip), which is
/// what took the old safety net away; layout is the replacement.
@MainActor
final class EditorLaunchAppearanceTests: XCTestCase {
    private var window: UIWindow!
    private var container: EditorContainerViewController!
    private var file: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first, "no scene to host in")
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        container = EditorContainerViewController()
        container.hostOwnsAppearanceTransitions = true // C4: the host owns the flip

        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-launch-appearance-\(UUID().uuidString).md")
        try Data("# launch\n".utf8).write(to: file)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        container = nil
        super.tearDown()
    }

    func testTheLaunchDocumentComesUpInTheAppsTheme() throws {
        // Opened while detached, exactly as the host does at launch.
        container.open(url: file)
        let detached = try XCTUnwrap(container.activeSurfaceDesiredDarkForTesting)

        // Host it under the OPPOSITE style. What the detached read produces is
        // the system's business (Catalyst answers with the Mac's own
        // appearance); what matters is that the window disagrees
        // with it, so the assertion below can fail.
        window.overrideUserInterfaceStyle = detached ? .light : .dark
        window.rootViewController = container
        window.isHidden = false
        container.loadViewIfNeeded()
        window.layoutIfNeeded()

        XCTAssertEqual(container.activeSurfaceDesiredDarkForTesting, !detached,
                       "the document opened at launch must show the app's theme, not the trait it read while detached")
    }

    /// The resync must never re-push what the covered transition already
    /// pushed: that flip would land outside the cover, which is the tear
    /// standing the hook down exists to prevent.
    func testASurfaceThatAlreadyAgreesIsNotPushedAgain() throws {
        container.open(url: file)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = container
        window.isHidden = false
        container.loadViewIfNeeded()
        window.layoutIfNeeded()

        container.pushAppearance(dark: true, theme: .ink) // what the covered flip does
        let pushes = container.activeSurfaceAppearancePushCountForTesting
        window.setNeedsLayout()
        window.layoutIfNeeded()
        window.setNeedsLayout()
        window.layoutIfNeeded()

        XCTAssertEqual(container.activeSurfaceDesiredDarkForTesting, true)
        XCTAssertEqual(container.activeSurfaceAppearancePushCountForTesting, pushes,
                       "an agreeing surface is left alone")
    }
}
