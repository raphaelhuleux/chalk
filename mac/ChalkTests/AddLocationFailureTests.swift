import XCTest
import ChalkKit
@testable import Chalk

/// Picking a folder that the Library then fails to store used to drop it
/// silently: the picker closed and nothing appeared. The user is told.
@MainActor
final class AddLocationFailureTests: XCTestCase {
    private var window: UIWindow?
    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-add-alert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.rootViewController?.presentedViewController?.dismiss(animated: false)
        window?.isHidden = true
        window = nil
        try? FileManager.default.removeItem(at: folder)
        try super.tearDownWithError()
    }

    func testAFolderThatCouldNotBeAddedIsReported() throws {
        // An isolated store whose saved Locations are unreadable, so the add
        // is refused (and the owner's real Library is never touched).
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "chalk-add-alert-\(UUID().uuidString)"))
        defaults.set(Data("not json".utf8), forKey: "locations")
        let bookmarks = BookmarkStore(defaults: defaults, key: "locations")
        let root = RootSplitViewController(
            locationStore: LocationStore(bookmarks: bookmarks), initialContent: .openEmpty)
        root.motionPolicyForTesting = .instant
        let window = UIWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1180, height: 820))
        window.rootViewController = root
        window.isHidden = false
        self.window = window
        root.applyTransitionForTesting(.sidebar(true))
        root.view.layoutIfNeeded()

        root.sidebarForTesting.onAddLocation?(folder)

        let alert = try XCTUnwrap(root.sidebarForTesting.presentedViewController as? UIAlertController)
        XCTAssertTrue(alert.message?.contains(folder.lastPathComponent) == true)
    }
}
