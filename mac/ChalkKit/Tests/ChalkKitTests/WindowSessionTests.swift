import XCTest
@testable import ChalkKit

/// A window's restoration snapshot must survive the round trip through
/// NSUserActivity userInfo, and the decode side must never trust the payload:
/// a version-skewed or tampered snapshot may not crash the restore path.
final class WindowSessionTests: XCTestCase {
    private func record(_ path: String) -> WindowSession.TabRecord {
        WindowSession.TabRecord(path: path, bookmark: nil)
    }

    func testEncodeDecodeRoundTrip() throws {
        let session = WindowSession(
            tabs: [record("/a/one.md"), record("/b/two.tex")],
            activeIndex: 1, isSidebarVisible: true)
        let data = try XCTUnwrap(session.encoded())
        let decoded = try XCTUnwrap(WindowSession(data: data))
        XCTAssertEqual(decoded, session)
    }

    func testBookmarkDataSurvivesRoundTrip() throws {
        let bookmark = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let session = WindowSession(
            tabs: [WindowSession.TabRecord(path: "/a.md", bookmark: bookmark)],
            activeIndex: 0, isSidebarVisible: false)
        let decoded = try XCTUnwrap(WindowSession(data: XCTUnwrap(session.encoded())))
        XCTAssertEqual(decoded.tabs.first?.bookmark, bookmark)
    }

    func testOutOfRangeActiveIndexClampsToFirstTab() {
        let session = WindowSession(
            tabs: [record("/a.md")], activeIndex: 7, isSidebarVisible: false)
        XCTAssertEqual(session.activeIndex, 0)
    }

    func testNegativeActiveIndexClampsToFirstTab() {
        let session = WindowSession(
            tabs: [record("/a.md")], activeIndex: -1, isSidebarVisible: false)
        XCTAssertEqual(session.activeIndex, 0)
    }

    func testEmptyTabsNilActiveIndex() {
        let session = WindowSession(tabs: [], activeIndex: 3, isSidebarVisible: true)
        XCTAssertNil(session.activeIndex)
    }

    func testGarbageDataDecodesToNil() {
        XCTAssertNil(WindowSession(data: Data([0x00, 0x01, 0x02])))
        XCTAssertNil(WindowSession(data: Data("{\"nope\":true}".utf8)))
    }

    func testTamperedActiveIndexIsReclampedOnDecode() throws {
        // Bypass the memberwise init's clamp by hand-writing the JSON a hostile
        // or version-skewed encoder could produce.
        let json = """
        {"tabs":[{"path":"/a.md"}],"activeIndex":42,"isSidebarVisible":false}
        """
        let decoded = try XCTUnwrap(WindowSession(data: Data(json.utf8)))
        XCTAssertEqual(decoded.activeIndex, 0)
    }

    func testFileBookmarkRoundTrip() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-bookmark-\(UUID().uuidString).md")
        try Data("# hi\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let bookmark = try XCTUnwrap(FileBookmark.make(for: file))
        let resolved = try XCTUnwrap(FileBookmark.resolve(bookmark))
        XCTAssertEqual(
            resolved.standardizedFileURL.resolvingSymlinksInPath(),
            file.standardizedFileURL.resolvingSymlinksInPath())
    }

    func testFileBookmarkGarbageResolvesToNil() {
        XCTAssertNil(FileBookmark.resolve(Data([0x00, 0x01])))
    }

    func testOutlineVisibilityRoundTrips() throws {
        let session = WindowSession(
            tabs: [record("/a.md")], activeIndex: 0,
            isSidebarVisible: false, isOutlineVisible: true)
        let decoded = try XCTUnwrap(WindowSession(data: XCTUnwrap(session.encoded())))
        XCTAssertTrue(decoded.isOutlineVisible)
    }

    /// A record written before the panel existed carries no key; it must
    /// restore, with the panel closed.
    func testRecordWithoutOutlineKeyDecodesClosed() throws {
        let legacy = Data(#"{"tabs":[{"path":"/a.md"}],"activeIndex":0,"isSidebarVisible":true}"#.utf8)
        let decoded = try XCTUnwrap(WindowSession(data: legacy))
        XCTAssertFalse(decoded.isOutlineVisible)
        XCTAssertTrue(decoded.isSidebarVisible)
    }

    func testSplitRoundTrip() throws {
        let session = WindowSession(
            tabs: [record("/a.md"), record("/b.md"), record("/c.md")],
            activeIndex: 0, isSidebarVisible: false, splitIndex: 2, splitIsLeading: true)
        let decoded = try XCTUnwrap(WindowSession(data: XCTUnwrap(session.encoded())))
        XCTAssertEqual(decoded.splitIndex, 2)
        XCTAssertTrue(decoded.splitIsLeading)
    }

    func testJournalWithoutSplitDecodesAsNoSplit() throws {
        let json = """
        {"tabs":[{"path":"/a.md"},{"path":"/b.md"}],"activeIndex":1,"isSidebarVisible":false}
        """
        let decoded = try XCTUnwrap(WindowSession(data: Data(json.utf8)))
        XCTAssertNil(decoded.splitIndex)
        XCTAssertFalse(decoded.splitIsLeading)
    }

    func testSplitRepeatingTheActiveTabIsDropped() {
        let session = WindowSession(
            tabs: [record("/a.md"), record("/b.md")],
            activeIndex: 1, isSidebarVisible: false, splitIndex: 1, splitIsLeading: true)
        XCTAssertNil(session.splitIndex)
        XCTAssertFalse(session.splitIsLeading)
    }

    func testOutOfRangeSplitIsDropped() {
        let session = WindowSession(
            tabs: [record("/a.md")], activeIndex: 0, isSidebarVisible: false, splitIndex: 4)
        XCTAssertNil(session.splitIndex)
    }
}
