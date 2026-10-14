import XCTest
import ChalkKit
@testable import Chalk

/// A draft is saved in the language it was created in. The default-file-type
/// preference only picks that language at Cmd+N; changing it later must not
/// turn an open LaTeX draft into a `.md` file at its first save.
final class DraftSaveFileTypeTests: XCTestCase {
    private var savedDefault: DefaultFileType!
    private var editor: EditorContainerViewController!

    override func setUp() {
        super.setUp()
        // Preferences is the real app's UserDefaults: snapshot here, restore in
        // tearDown (see PreferencePollutionGuardTests).
        savedDefault = Preferences.defaultFileType
        editor = EditorContainerViewController()
        editor.loadViewIfNeeded()
    }

    override func tearDown() {
        Preferences.defaultFileType = savedDefault
        editor = nil
        super.tearDown()
    }

    func testDraftSavesWithItsOwnExtensionAfterTheDefaultChanges() throws {
        Preferences.defaultFileType = .tex
        editor.newFile()
        Preferences.defaultFileType = .md

        editor.save()

        let file = try XCTUnwrap(editor.pendingDraftSaveFileForTesting,
                                 "the save panel was handed a file")
        XCTAssertEqual(file.pathExtension, "tex")
    }
}
