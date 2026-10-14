import XCTest
@testable import ChalkKit

/// The sidebar's move, and the one fact about it that no test asserted before
/// 2026-08-24: WHICH THREAD it runs on.
///
/// A coordinated write waits for every file presenter of the two URLs to
/// relinquish — the CloudDocs daemon for an iCloud Location, and the app's own
/// open `UIDocument` when the moved file is the one on screen. On the main
/// thread that wait IS the beachball the owner reported for rename and for
/// drag-into-folder (the two callers of `SidebarViewController.moveFile`).
///
/// The `accessor` seam exists for these tests: it stands in for the real
/// `NSFileCoordinator` work so the threading contract can be pinned without a
/// daemon in the loop. `testTheRealAccessorMovesTheFile` covers the real one.
final class CoordinatedFileMoveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func file(_ name: String, contents: String = "hello") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - The threading contract

    /// The reported freeze, as an assertion: the move must not run on the
    /// thread that draws.
    func testTheMoveRunsOffTheMainThread() throws {
        let source = try file("draft.md")
        let ranOnMainThread = Locked(false)
        let done = expectation(description: "move finished")

        CoordinatedFileMove.perform(
            from: source, to: directory.appendingPathComponent("notes.md"),
            accessor: { _, _ in
                ranOnMainThread.set(Thread.isMainThread)
                return nil
            },
            completion: { _ in done.fulfill() })

        wait(for: [done], timeout: 2)
        XCTAssertFalse(ranOnMainThread.get(),
                       "a coordinated write on the main thread is the beachball")
    }

    /// Everything the completion touches is UIKit state (the tree apply, the
    /// undo registration, an alert), so it has to land back on main.
    func testTheCompletionLandsOnTheMainThread() throws {
        let source = try file("draft.md")
        let onMainThread = Locked(false)
        let done = expectation(description: "completion ran")

        CoordinatedFileMove.perform(
            from: source, to: directory.appendingPathComponent("notes.md"),
            accessor: { _, _ in nil },
            completion: { _ in
                onMainThread.set(Thread.isMainThread)
                done.fulfill()
            })

        wait(for: [done], timeout: 2)
        XCTAssertTrue(onMainThread.get())
    }

    func testTheAccessorSeesTheSourceAndDestination() throws {
        let source = try file("draft.md")
        let destination = directory.appendingPathComponent("notes.md")
        let seen = Locked<[URL]>([])
        let done = expectation(description: "move finished")

        CoordinatedFileMove.perform(
            from: source, to: destination,
            accessor: { from, to in
                seen.set([from, to])
                return nil
            },
            completion: { _ in done.fulfill() })

        wait(for: [done], timeout: 2)
        XCTAssertEqual(seen.get(), [source, destination])
    }

    // MARK: - Success and failure both reach the caller

    func testSuccessReportsNoError() throws {
        let source = try file("draft.md")
        let reported = Locked<Error?>(nil)
        let done = expectation(description: "move finished")

        CoordinatedFileMove.perform(
            from: source, to: directory.appendingPathComponent("notes.md"),
            accessor: { _, _ in nil },
            completion: { error in
                reported.set(error)
                done.fulfill()
            })

        wait(for: [done], timeout: 2)
        XCTAssertNil(reported.get())
    }

    /// A failure must not be swallowed: the callers turn it into the "Couldn't
    /// move …" surface rather than leaving the row silently unchanged.
    func testFailureReachesTheCompletion() throws {
        let source = try file("draft.md")
        let reported = Locked<Error?>(nil)
        let done = expectation(description: "move finished")
        let failure = NSError(domain: "test", code: 7)

        CoordinatedFileMove.perform(
            from: source, to: directory.appendingPathComponent("notes.md"),
            accessor: { _, _ in failure },
            completion: { error in
                reported.set(error)
                done.fulfill()
            })

        wait(for: [done], timeout: 2)
        XCTAssertEqual(reported.get() as NSError?, failure)
    }

    // MARK: - The real accessor

    /// The default accessor is the `NSFileCoordinator` work lifted out of the
    /// sidebar: in a plain temp directory (no presenters) it is an ordinary
    /// move, and that is what this pins.
    func testTheRealAccessorMovesTheFile() throws {
        let source = try file("draft.md", contents: "carried across")
        let destination = directory.appendingPathComponent("notes.md")
        let done = expectation(description: "move finished")
        let reported = Locked<Error?>(nil)

        CoordinatedFileMove.perform(from: source, to: destination) { error in
            reported.set(error)
            done.fulfill()
        }

        wait(for: [done], timeout: 5)
        XCTAssertNil(reported.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "carried across")
    }

    /// A move whose source is gone fails rather than reporting success.
    func testTheRealAccessorReportsAMissingSource() {
        let done = expectation(description: "move finished")
        let reported = Locked<Error?>(nil)

        CoordinatedFileMove.perform(
            from: directory.appendingPathComponent("nothing-here.md"),
            to: directory.appendingPathComponent("notes.md")
        ) { error in
            reported.set(error)
            done.fulfill()
        }

        wait(for: [done], timeout: 5)
        XCTAssertNotNil(reported.get())
    }
}

/// Test-local box for a value written on one queue and read on another, so the
/// assertions do not race the work they are about.
private final class Locked<Value> {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
