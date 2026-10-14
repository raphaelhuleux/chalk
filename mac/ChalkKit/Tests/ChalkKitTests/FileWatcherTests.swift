import XCTest
@testable import ChalkKit

final class FileWatcherTests: XCTestCase {
    private var dir: URL!
    private var file: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("note.md")
        try Data("a".utf8).write(to: file)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testInPlaceWriteFires() throws {
        let fired = expectation(description: "change")
        let watcher = FileWatcher(url: file, debounce: 0.05) { fired.fulfill() }
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data("b".utf8))
        try handle.close()
        wait(for: [fired], timeout: 2)
        watcher.cancel()
    }

    /// An atomic save swaps the inode; the watch must follow the path to the new one.
    func testFollowsAtomicReplaceThenSeesLaterWrites() throws {
        var count = 0
        let first = expectation(description: "atomic replace")
        let second = expectation(description: "write after replace")
        let watcher = FileWatcher(url: file, debounce: 0.05) {
            count += 1
            if count == 1 { first.fulfill() } else if count == 2 { second.fulfill() }
        }
        try Data("b".utf8).write(to: file, options: .atomic)
        wait(for: [first], timeout: 2)
        try Data("c".utf8).write(to: file, options: .atomic)
        wait(for: [second], timeout: 2)
        watcher.cancel()
    }

    func testFiresWhenDeletedFileIsRecreated() throws {
        var count = 0
        let recreated = expectation(description: "recreated")
        let watcher = FileWatcher(url: file, debounce: 0.05) {
            count += 1
            if FileManager.default.fileExists(atPath: self.file.path) { recreated.fulfill() }
        }
        try FileManager.default.removeItem(at: file)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            try? Data("new".utf8).write(to: self.file)
        }
        wait(for: [recreated], timeout: 3)
        watcher.cancel()
    }

    func testCancelStopsCallbacks() throws {
        let fired = expectation(description: "no change after cancel")
        fired.isInverted = true
        let watcher = FileWatcher(url: file, debounce: 0.05) { fired.fulfill() }
        watcher.cancel()
        try Data("b".utf8).write(to: file, options: .atomic)
        wait(for: [fired], timeout: 0.5)
    }
}
