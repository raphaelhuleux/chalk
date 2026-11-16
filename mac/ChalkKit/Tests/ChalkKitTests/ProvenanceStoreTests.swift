import XCTest
@testable import ChalkKit

final class ProvenanceStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ProvenanceStore!
    private let mark = AiMark(from: 1, to: 3, deleted: "old")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-marks-\(UUID().uuidString)", isDirectory: true)
        store = ProvenanceStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var files: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    func testARecordSurvivesANewStore() {
        let record = AiMarkRecord(path: "/a.md", text: "body", marks: [mark])
        store.save(record)
        store.flush()
        XCTAssertEqual(ProvenanceStore(directory: directory).load(path: "/a.md"), record)
    }

    func testRemovalDeletesTheFile() {
        store.save(AiMarkRecord(path: "/a.md", text: "body", marks: [mark]))
        store.flush()
        XCTAssertEqual(files.count, 1)
        store.remove(path: "/a.md")
        store.flush()
        XCTAssertTrue(files.isEmpty)
        XCTAssertNil(store.load(path: "/a.md"))
    }

    func testLoadSeesAWriteStillQueued() {
        let record = AiMarkRecord(path: "/a.md", text: "body", marks: [mark])
        store.save(record)
        XCTAssertEqual(store.load(path: "/a.md"), record)
        store.remove(path: "/a.md")
        XCTAssertNil(store.load(path: "/a.md"))
    }

    func testMoveFollowsARename() {
        store.save(AiMarkRecord(path: "/a.md", text: "body", marks: [mark]))
        store.move(from: "/a.md", to: "/b.md")
        store.flush()
        XCTAssertNil(store.load(path: "/a.md"))
        XCTAssertEqual(store.load(path: "/b.md")?.path, "/b.md")
        XCTAssertEqual(files.count, 1)
    }

    func testACorruptFileReadsAsNoRecord() throws {
        store.save(AiMarkRecord(path: "/a.md", text: "body", marks: [mark]))
        store.flush()
        try Data("not json".utf8).write(to: XCTUnwrap(files.first))
        XCTAssertNil(store.load(path: "/a.md"))
    }

    func testOwnSavesKeepsOnlyRecentText() {
        let saves = OwnSaves()
        saves.record("first", path: "/a.md")
        XCTAssertTrue(saves.contains("first", path: "/a.md"))
        XCTAssertFalse(saves.contains("first", path: "/b.md"))
        for i in 0..<8 { saves.record("later \(i)", path: "/a.md") }
        XCTAssertFalse(saves.contains("first", path: "/a.md"))
    }
}
