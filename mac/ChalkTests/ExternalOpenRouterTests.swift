import XCTest
import ChalkKit
@testable import Chalk

/// Files and folders from outside (Finder, `open -a Chalk`, a Dock drop) go
/// to the right window, VS Code style: a folder already shown comes forward,
/// a pristine window takes a new folder, a busy one hands it to a new window,
/// and a file inside some window's roots opens there.
@MainActor
final class ExternalOpenRouterTests: XCTestCase {
    private var tempDir: URL!
    private var roots: [RootSplitViewController] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-extopen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        roots = []
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func folder(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A window showing `folders` in its Library.
    private func window(showing folders: [URL] = []) -> RootSplitViewController {
        let root = RootSplitViewController(initialContent: .openEmpty)
        root.loadViewIfNeeded()
        if !folders.isEmpty { root.setLibraryLocationsForTesting(folders) }
        roots.append(root)
        return root
    }

    private final class Forwarded {
        var count = 0
    }

    private func candidate(_ root: RootSplitViewController, _ forwarded: Forwarded) -> ExternalOpenRouter.Candidate {
        ExternalOpenRouter.Candidate(root: root) { forwarded.count += 1 }
    }

    func testAFolderAlreadyShownComesForwardInstead() throws {
        let shown = try folder("shown")
        let receiver = window()
        let other = window(showing: [shown])
        let forwarded = Forwarded()
        var made = 0

        ExternalOpenRouter.route([shown], receivedBy: receiver,
                                 candidates: [candidate(receiver, Forwarded()), candidate(other, forwarded)]) {
            made += 1
            return self.window()
        }

        XCTAssertEqual(forwarded.count, 1, "the window showing the folder comes forward")
        XCTAssertTrue(receiver.isPristine, "the receiver does not get a second copy")
        XCTAssertEqual(made, 0)
    }

    func testAPristineReceiverTakesANewFolder() throws {
        let fresh = try folder("fresh")
        let receiver = window()
        var made = 0

        ExternalOpenRouter.route([fresh], receivedBy: receiver, candidates: [candidate(receiver, Forwarded())]) {
            made += 1
            return self.window()
        }

        XCTAssertEqual(receiver.locationStore.locations().map(\.url.fileIdentity), [fresh.fileIdentity])
        XCTAssertTrue(receiver.isSidebarVisible, "the Library shows what just arrived")
        XCTAssertEqual(made, 0)
    }

    func testABusyReceiverHandsANewFolderToANewWindow() throws {
        let fresh = try folder("fresh")
        let receiver = window()
        receiver.editor.newFile()
        XCTAssertFalse(receiver.isPristine, "precondition: a draft makes the window busy")
        var opened: RootSplitViewController?

        ExternalOpenRouter.route([fresh], receivedBy: receiver, candidates: [candidate(receiver, Forwarded())]) {
            let root = self.window()
            opened = root
            return root
        }

        XCTAssertTrue(receiver.locationStore.locations().isEmpty, "the busy window keeps its own folders")
        XCTAssertEqual(opened?.locationStore.locations().map(\.url.fileIdentity), [fresh.fileIdentity])
    }

    func testAFileInsideAnotherWindowsRootsOpensThere() throws {
        let notes = try folder("notes")
        let doc = try file("doc.md", in: notes)
        let receiver = window()
        let owner = window(showing: [notes])
        let forwarded = Forwarded()

        ExternalOpenRouter.route([doc], receivedBy: receiver,
                                 candidates: [candidate(receiver, Forwarded()), candidate(owner, forwarded)]) {
            XCTFail("no new window for a file")
            return self.window()
        }

        XCTAssertEqual(owner.openTabCount, 1)
        XCTAssertEqual(receiver.openTabCount, 0)
        XCTAssertEqual(forwarded.count, 1, "the window that took the file comes forward")
    }

    func testAFileNoWindowShowsOpensInTheReceiver() throws {
        let elsewhere = try folder("elsewhere")
        let doc = try file("doc.md", in: elsewhere)
        let receiver = window()
        let other = window(showing: [try folder("other")])

        ExternalOpenRouter.route([doc], receivedBy: receiver,
                                 candidates: [candidate(receiver, Forwarded()), candidate(other, Forwarded())]) {
            XCTFail("no new window for a file")
            return self.window()
        }

        XCTAssertEqual(receiver.openTabCount, 1)
        XCTAssertEqual(other.openTabCount, 0)
    }

    /// The receiver showing the file's folder itself: no forward, no second tab.
    func testAFileInsideTheReceiversOwnRootsStaysThere() throws {
        let notes = try folder("notes")
        let doc = try file("doc.md", in: notes)
        let receiver = window(showing: [notes])
        let forwarded = Forwarded()

        ExternalOpenRouter.route([doc], receivedBy: receiver, candidates: [candidate(receiver, forwarded)]) {
            XCTFail("no new window for a file")
            return self.window()
        }

        XCTAssertEqual(receiver.openTabCount, 1)
        XCTAssertEqual(forwarded.count, 0)
    }
}
