import XCTest
import ChalkKit
@testable import ChalkMac

/// Multi-window sync contracts: Library mutations broadcast so every window's
/// sidebar reloads, and a save broadcasts so other windows with the same file
/// open adopt the new contents (clean buffers only — dirty local edits win).
final class CrossWindowSyncTests: XCTestCase {
    // MARK: - LocationStore broadcasts

    private func isolatedStore() throws -> LocationStore {
        let suite = "chalk-xwin-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return LocationStore(bookmarks: BookmarkStore(defaults: defaults, key: "locations"))
    }

    private func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-xwin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testAddLocationPostsLibraryDidChange() throws {
        let store = try isolatedStore()
        let posted = expectation(forNotification: .chalkLibraryDidChange, object: store)
        store.add(url: try tempFolder())
        wait(for: [posted], timeout: 2)
    }

    func testRemoveLocationPostsLibraryDidChange() throws {
        let store = try isolatedStore()
        let posted = expectation(forNotification: .chalkLibraryDidChange, object: store)
        posted.expectedFulfillmentCount = 2 // once for add, once for remove
        store.add(url: try tempFolder())
        let id = try XCTUnwrap(store.locations().last?.id)
        store.remove(id: id)
        wait(for: [posted], timeout: 2)
    }

    func testReauthorizePostsLibraryDidChange() throws {
        let store = try isolatedStore()
        let posted = expectation(forNotification: .chalkLibraryDidChange, object: store)
        store.reauthorize(id: "missing", with: try tempFolder())
        wait(for: [posted], timeout: 2)
    }

    // MARK: - Save broadcast + adoption (two controllers = two windows)

    /// Open `url` in a fresh controller/surface pair, wired like a real tab.
    private func makeOpenController(for url: URL) -> (DocumentController, FakeEditorSurface, DirtySpy) {
        let surface = FakeEditorSurface()
        let controller = DocumentController(surface: surface)
        let spy = DirtySpy()
        controller.delegate = spy
        surface.signalReady()
        let opened = expectation(description: "open \(url.lastPathComponent)")
        spy.onDirtyChange = { _ in opened.fulfill() }
        controller.open(url: url)
        wait(for: [opened], timeout: 5)
        spy.onDirtyChange = nil
        return (controller, surface, spy)
    }

    private func writeTempFile(contents: String) throws -> URL {
        let url = try tempFolder().appendingPathComponent("doc.md")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testSavePostsDocumentDidSaveWithURL() throws {
        let url = try writeTempFile(contents: "# One\n")
        let (a, surfaceA, _) = makeOpenController(for: url)

        a.editor(surfaceA, didEdit: "# One\nedited\n")
        let posted = expectation(forNotification: .chalkDocumentDidSave, object: a) { note in
            guard let posted = note.userInfo?[ChalkNotificationKey.url] as? URL else { return false }
            return posted.standardizedFileURL.resolvingSymlinksInPath()
                == url.standardizedFileURL.resolvingSymlinksInPath()
        }
        a.save()
        wait(for: [posted], timeout: 5)
    }

    func testCleanSecondControllerAdoptsSavedText() throws {
        let url = try writeTempFile(contents: "# One\n")
        let (a, surfaceA, _) = makeOpenController(for: url)
        let (b, surfaceB, _) = makeOpenController(for: url)

        a.editor(surfaceA, didEdit: "# One\nfrom window A\n")
        let posted = expectation(forNotification: .chalkDocumentDidSave, object: a)
        a.save()
        wait(for: [posted], timeout: 5)

        // What EditorContainer's `.chalkDocumentDidSave` observer runs on B.
        // The coordinated read is async (utility queue + main hop) — wait for
        // the adoption to land.
        let adopted = expectation(description: "B adopts A's save")
        surfaceB.onDisplayedTextChange = { text in
            if text == "# One\nfrom window A\n" { adopted.fulfill() }
        }
        b.reloadIfChangedExternally()
        wait(for: [adopted], timeout: 5)
        surfaceB.onDisplayedTextChange = nil

        XCTAssertEqual(surfaceB.displayedText, "# One\nfrom window A\n",
                       "a clean tab in another window must adopt the saved text")
        XCTAssertFalse(b.isDirty)
    }

    func testDirtySecondControllerKeepsItsEdits() throws {
        let url = try writeTempFile(contents: "# One\n")
        let (a, surfaceA, _) = makeOpenController(for: url)
        let (b, surfaceB, _) = makeOpenController(for: url)

        b.editor(surfaceB, didEdit: "# One\nlocal B edit\n")
        XCTAssertTrue(b.isDirty)

        a.editor(surfaceA, didEdit: "# One\nfrom window A\n")
        let posted = expectation(forNotification: .chalkDocumentDidSave, object: a)
        a.save()
        wait(for: [posted], timeout: 5)

        b.reloadIfChangedExternally()
        // Async read: give a wrong adoption time to land before asserting.
        let settle = expectation(description: "reload settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        wait(for: [settle], timeout: 5)

        XCTAssertTrue(b.isDirty, "dirty local edits must survive a save elsewhere")
        XCTAssertFalse(surfaceB.updateTexts.contains("# One\nfrom window A\n"),
                       "the other window's text must not be pushed over local edits")
    }
}
