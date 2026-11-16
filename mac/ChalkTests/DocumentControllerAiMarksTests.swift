import XCTest
import ChalkKit
@testable import Chalk

/// What the host decides about AI marks: which text pushes count as outside writes, and how marks
/// survive a reopen. The marking itself is editor-core's (test/provenance.test.ts).
@MainActor
final class DocumentControllerAiMarksTests: XCTestCase {
    private var directory: URL!
    private var file: URL!
    private var store: ProvenanceStore!
    private var surface: FakeEditorSurface!
    private var controller: DocumentController!
    private let mark = AiMark(from: 0, to: 3, deleted: "old")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("note.md")
        try "one two".write(to: file, atomically: true, encoding: .utf8)
        store = ProvenanceStore(directory: directory.appendingPathComponent("marks"))
        surface = FakeEditorSurface()
        controller = DocumentController(surface: surface, provenance: store)
        Preferences.markOutsideWrites = true
    }

    override func tearDown() {
        controller.close()
        UserDefaults.standard.removeObject(forKey: "chalk.markOutsideWrites")
        try? FileManager.default.removeItem(at: directory)
    }

    private func open() {
        let seeded = expectation(description: "seeded")
        surface.onDisplayedTextChange = { [weak surface] _ in
            surface?.onDisplayedTextChange = nil
            seeded.fulfill()
        }
        controller.open(url: file)
        surface.signalReady()
        wait(for: [seeded], timeout: 5)
    }

    /// Writes `text` from "outside" and waits for it to land. The size changes, which is what the
    /// reload's stat baseline looks at.
    private func writeOutside(_ text: String) throws {
        try text.write(to: file, atomically: true, encoding: .utf8)
        let landed = expectation(description: "reloaded")
        surface.onDisplayedTextChange = { [weak surface] shown in
            guard shown == text else { return }
            surface?.onDisplayedTextChange = nil
            landed.fulfill()
        }
        controller.reloadIfChangedExternally()
        wait(for: [landed], timeout: 5)
    }

    func testAPlainOpenPushesNoMarks() {
        open()
        XCTAssertEqual(surface.textPushes.count, 1)
        XCTAssertNil(surface.textPushes[0].aiMarks)
    }

    func testAnOutsideWriteIsPushedAsExternal() throws {
        open()
        try writeOutside("one two three")
        XCTAssertEqual(surface.textPushes.last?.origin, .external)
    }

    func testTheSettingStopsMarking() throws {
        Preferences.markOutsideWrites = false
        open()
        try writeOutside("one two three")
        XCTAssertNil(surface.textPushes.last?.origin)
    }

    func testAnotherWindowsSaveIsNotAnOutsideWrite() throws {
        open()
        OwnSaves.shared.record("saved elsewhere", path: file.fileIdentity)
        try writeOutside("saved elsewhere")
        XCTAssertNil(surface.textPushes.last?.origin)
    }

    func testStoredMarksComeBackWithTheirText() {
        store.save(AiMarkRecord(path: file.fileIdentity, text: "one two", marks: [mark]))
        open()
        XCTAssertEqual(surface.textPushes.count, 1)
        XCTAssertEqual(surface.textPushes[0].text, "one two")
        XCTAssertEqual(surface.textPushes[0].aiMarks, [mark])
    }

    func testAWriteWhileClosedIsMarkedOnReopen() {
        store.save(AiMarkRecord(path: file.fileIdentity, text: "before", marks: [mark]))
        open()
        XCTAssertEqual(surface.textPushes.map(\.text), ["before", "one two"])
        XCTAssertEqual(surface.textPushes[0].aiMarks, [mark])
        XCTAssertEqual(surface.textPushes[1].origin, .external)
    }

    func testAPushIsStoredAndClearingRemovesTheRecord() {
        open()
        controller.editor(surface, didChangeAiMarks: [mark], text: "one two")
        XCTAssertEqual(store.load(path: file.fileIdentity)?.marks, [mark])
        controller.editor(surface, didChangeAiMarks: [], text: "one two")
        XCTAssertNil(store.load(path: file.fileIdentity))
    }

    func testAPushForOtherTextIsIgnored() {
        open()
        controller.editor(surface, didChangeAiMarks: [mark], text: "the previous file")
        XCTAssertNil(store.load(path: file.fileIdentity))
    }

    func testARenameCarriesTheRecord() throws {
        open()
        controller.editor(surface, didChangeAiMarks: [mark], text: "one two")
        let renamed = directory.appendingPathComponent("renamed.md")
        try FileManager.default.moveItem(at: file, to: renamed)
        controller.rebind(to: renamed)
        XCTAssertNil(store.load(path: file.fileIdentity))
        XCTAssertEqual(store.load(path: renamed.fileIdentity)?.marks, [mark])
    }
}
