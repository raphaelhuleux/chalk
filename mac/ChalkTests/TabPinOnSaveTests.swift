import XCTest
import ChalkKit
@testable import Chalk

/// An explicit Cmd+S pins the browse tab: "I am working in this file", so the
/// next sidebar click opens a NEW tab instead of replacing it — even when the
/// buffer was clean and the save wrote nothing. Automatic saves must not pin
/// (D11): a resign-active `saveAll` while you browse a folder would otherwise
/// turn every visited file into a permanent tab.
final class TabPinOnSaveTests: XCTestCase {
    private var editor: EditorContainerViewController!
    private var dir: URL!

    override func setUp() {
        super.setUp()
        editor = EditorContainerViewController()
        editor.loadViewIfNeeded()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-pin-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        editor = nil
        dir = nil
        super.tearDown()
    }

    private func file(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("body\n".utf8).write(to: url)
        return url
    }

    /// The control: browse-reuse itself is untouched.
    func testPlainBrowseClicksKeepReusingTheSameTab() throws {
        editor.open(url: try file("a.md"), reuseCurrentIfClean: true)
        editor.open(url: try file("b.md"), reuseCurrentIfClean: true)
        XCTAssertEqual(editor.tabItemsForTesting.count, 1,
                       "clicking through the tree must not spawn tabs")
    }

    /// Menu / key-command Cmd+S, nothing typed.
    func testExplicitSavePinsTheTabEvenWithNothingToWrite() throws {
        editor.open(url: try file("a.md"), reuseCurrentIfClean: true)
        editor.save()
        editor.open(url: try file("b.md"), reuseCurrentIfClean: true)
        let items = editor.tabItemsForTesting
        XCTAssertEqual(items.count, 2, "the saved file must survive the next sidebar click")
        XCTAssertFalse(items[0].isPreview, "a saved tab is no longer disposable")
    }

    /// The Mac path: a focused webview swallows Cmd+S and forwards it, which
    /// reaches DocumentController.save() directly, never the container's.
    func testWebForwardedSaveAlsoPinsTheTab() throws {
        editor.open(url: try file("a.md"), reuseCurrentIfClean: true)
        let controller = try XCTUnwrap(editor.tabControllerForTesting(at: 0))
        controller.editor(FakeEditorSurface(), requestsCommand: ShellCommand.save.rawValue)
        editor.open(url: try file("b.md"), reuseCurrentIfClean: true)
        XCTAssertEqual(editor.tabItemsForTesting.count, 2,
                       "Cmd+S must pin the tab on Mac too, where the key arrives through the editor")
    }

    /// D11: the background flush is not a statement of intent.
    func testAutomaticSaveAllDoesNotPinAnUneditedTab() throws {
        editor.open(url: try file("a.md"), reuseCurrentIfClean: true)
        let flushed = expectation(description: "saveAll")
        editor.saveAll { flushed.fulfill() }
        wait(for: [flushed], timeout: 5)
        editor.open(url: try file("b.md"), reuseCurrentIfClean: true)
        XCTAssertEqual(editor.tabItemsForTesting.count, 1,
                       "resign-active must not turn every browsed file into a permanent tab")
    }
}
