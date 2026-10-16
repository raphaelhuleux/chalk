import XCTest
import ChalkKit
@testable import Chalk

/// The default YAML header is the user's own: the editor shows the stored text and Save
/// writes it back, which the next compile reads through `Preferences.compileSettings`.
@MainActor
final class MarkdownHeaderEditorTests: XCTestCase {
    private var previous: Any?
    private let key = "chalk.markdownDefaultHeader"

    override func setUp() {
        super.setUp()
        previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    func testStartsFromTheSuggestionAndSavesTheUsersText() {
        let editor = MarkdownHeaderEditorViewController()
        editor.loadViewIfNeeded()
        XCTAssertEqual(editor.textForTesting, Preferences.suggestedMarkdownHeader)
        editor.textForTesting = "title: Mine\nformat: pdf"
        editor.saveForTesting()
        XCTAssertEqual(Preferences.markdownDefaultHeader, "title: Mine\nformat: pdf")
    }
}
