import XCTest
@testable import ChalkKit

/// The AppKit shell's window journal: what a quit writes is what the next
/// launch reads, in order, frames included, and a bad payload reads as empty
/// rather than crashing the launch.
final class WindowSessionJournalTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: "chalk-journal-\(UUID().uuidString)"))
    }

    private func record(_ id: String, tabs: [String] = [], frame: WindowRecord.Frame? = nil) -> WindowRecord {
        WindowRecord(
            id: id,
            session: WindowSession(
                tabs: tabs.map { WindowSession.TabRecord(path: $0, bookmark: nil) },
                activeIndex: tabs.isEmpty ? nil : 0,
                isSidebarVisible: !tabs.isEmpty,
                isOutlineVisible: false),
            frame: frame)
    }

    func testAFreshJournalIsEmpty() {
        XCTAssertEqual(WindowSessionJournal(defaults: defaults).load(), [])
    }

    func testWhatIsSavedComesBackInOrder() {
        let journal = WindowSessionJournal(defaults: defaults)
        let front = record("front", tabs: ["/a.md", "/b.md"], frame: .init(x: 10, y: 20, width: 1100, height: 760))
        let back = record("back")
        journal.save([front, back])
        XCTAssertEqual(WindowSessionJournal(defaults: defaults).load(), [front, back])
    }

    func testSavingReplacesTheWholeList() {
        let journal = WindowSessionJournal(defaults: defaults)
        journal.save([record("one"), record("two")])
        journal.save([record("two")])
        XCTAssertEqual(journal.load().map(\.id), ["two"], "a closed window must not come back")
    }

    func testClearLeavesNothingToRestore() {
        let journal = WindowSessionJournal(defaults: defaults)
        journal.save([record("one")])
        journal.clear()
        XCTAssertEqual(journal.load(), [])
    }

    func testUndecodableBytesReadAsEmpty() {
        defaults.set(Data("not json".utf8), forKey: WindowSessionJournal.defaultKey)
        XCTAssertEqual(WindowSessionJournal(defaults: defaults).load(), [])
    }

    /// The journal and the per-window Locations share the window id: a
    /// restored record must find its folders under `WindowLocations.key`.
    func testRecordIDIsTheLocationsKey() {
        let journal = WindowSessionJournal(defaults: defaults)
        journal.save([record("win-1")])
        let id = journal.load()[0].id
        XCTAssertEqual(WindowLocations.key(forWindow: id), "chalk.window-locations.win-1")
    }
}
