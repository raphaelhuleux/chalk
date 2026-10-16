import XCTest
import ChalkKit
@testable import Chalk

/// The view-install invariant behind the P0 "blank editor with a live chip"
/// (docs/issues/2026-07-24-blank-editor-on-open.md): whenever a tab is active
/// its surface view MUST be in the container's hierarchy and the "No document
/// open" placeholder MUST be hidden — on every open path, including the ones
/// that used to skip view work (the dedupe re-activate and the sidebar
/// reuse-browse branch), and even if something detached the surface earlier.
final class EditorSurfaceInstallTests: XCTestCase {
    private var editor: EditorContainerViewController!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        editor = EditorContainerViewController()
        editor.loadViewIfNeeded()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-install-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        editor = nil
        super.tearDown()
    }

    private func writeTempFile(name: String, contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The active surface's hosted view (the seam's `view`), which is what
    /// the container installs; the web view inside it is the surface's own.
    private var activeSurfaceView: NSView? {
        guard let index = editor.tabItemsForTesting.firstIndex(where: \.isActive) else { return nil }
        return editor.tabSurfaceForTesting(at: index)?.view
    }

    private var activeSurfaceSuperview: NSView? { activeSurfaceView?.superview }

    func testFreshContainerShowsEmptyState() {
        XCTAssertTrue(editor.isEmptyStateVisibleForTesting,
                      "no tab open — the placeholder is the honest state")
    }

    func testOpenInstallsSurfaceAndHidesEmptyState() throws {
        let url = try writeTempFile(name: "a.md", contents: "hello\n")
        editor.open(url: url)
        XCTAssertNotNil(activeSurfaceSuperview,
                        "the active tab's surface view must be in the hierarchy")
        XCTAssertFalse(editor.isEmptyStateVisibleForTesting,
                       "a live tab must never sit over the 'No document open' placeholder")
    }

    func testDedupeReactivateReinstallsDetachedSurface() throws {
        let url = try writeTempFile(name: "a.md", contents: "hello\n")
        editor.open(url: url)
        activeSurfaceView?.removeFromSuperview() // the pathology

        editor.open(url: url) // dedupe branch: activeTab === tab

        XCTAssertNotNil(activeSurfaceSuperview,
                        "re-activating the already-active tab must repair a detached surface")
        XCTAssertFalse(editor.isEmptyStateVisibleForTesting)
    }

    func testSidebarReuseBrowseRepairsDetachedSurface() throws {
        let a = try writeTempFile(name: "a.md", contents: "aaa\n")
        let b = try writeTempFile(name: "b.md", contents: "bbb\n")
        editor.open(url: a) // uncommitted preview tab
        activeSurfaceView?.removeFromSuperview() // the pathology

        editor.open(url: b, reuseCurrentIfClean: true) // sidebar browse click

        XCTAssertEqual(editor.tabItemsForTesting.count, 1,
                       "browse reuses the preview tab in place")
        XCTAssertNotNil(activeSurfaceSuperview,
                        "the reuse-browse path must never leave the chip live over a blank body")
        XCTAssertFalse(editor.isEmptyStateVisibleForTesting)
    }

    func testClosingLastTabShowsEmptyStateAgain() throws {
        let url = try writeTempFile(name: "a.md", contents: "hello\n")
        editor.open(url: url)
        editor.closeActiveTab()
        XCTAssertTrue(editor.isEmptyStateVisibleForTesting,
                      "no tabs left — the placeholder must come back")
    }
}
