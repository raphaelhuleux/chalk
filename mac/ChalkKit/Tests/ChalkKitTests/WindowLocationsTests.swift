import XCTest
@testable import ChalkKit

final class WindowLocationsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let legacy = try! JSONEncoder().encode(
        [LocationRecord(id: "old", name: "Notes", bookmark: Data([0x01]))])

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: "chalk-winloc-\(UUID().uuidString)"))
    }

    func testFirstWindowAfterUpdateInheritsTheLegacyList() {
        defaults.set(legacy, forKey: WindowLocations.legacyKey)
        let first = WindowLocations.store(forWindow: "A", isRestoredWindow: false, defaults: defaults)
        XCTAssertEqual(first.records().map(\.id), ["old"])
    }

    func testLaterNewWindowsStartEmpty() {
        defaults.set(legacy, forKey: WindowLocations.legacyKey)
        _ = WindowLocations.store(forWindow: "A", isRestoredWindow: false, defaults: defaults)
        let second = WindowLocations.store(forWindow: "B", isRestoredWindow: false, defaults: defaults)
        XCTAssertEqual(second.records(), [])
    }

    /// Every window open before the update keeps the folders it showed, whatever order they connect in.
    func testEveryRestoredWindowWithoutAListInheritsIt() {
        defaults.set(legacy, forKey: WindowLocations.legacyKey)
        _ = WindowLocations.store(forWindow: "A", isRestoredWindow: true, defaults: defaults)
        let b = WindowLocations.store(forWindow: "B", isRestoredWindow: true, defaults: defaults)
        XCTAssertEqual(b.records().map(\.id), ["old"])
    }

    func testAWindowKeepsItsOwnListAcrossRelaunch() throws {
        defaults.set(legacy, forKey: WindowLocations.legacyKey)
        let a = WindowLocations.store(forWindow: "A", isRestoredWindow: false, defaults: defaults)
        a.remove(id: "old")
        let again = WindowLocations.store(forWindow: "A", isRestoredWindow: true, defaults: defaults)
        XCTAssertEqual(again.records(), [], "an emptied list must not re-inherit the legacy one")
    }

    func testDiscardForgetsTheWindowsList() {
        _ = WindowLocations.store(forWindow: "A", isRestoredWindow: false, defaults: defaults)
        WindowLocations.discard(windows: ["A"], defaults: defaults)
        XCTAssertNil(defaults.object(forKey: WindowLocations.key(forWindow: "A")))
    }

    func testNoLegacyListMeansEmpty() {
        let a = WindowLocations.store(forWindow: "A", isRestoredWindow: true, defaults: defaults)
        XCTAssertEqual(a.records(), [])
    }

    /// A list no restorable window owns is a leak from a process that died before journaling it.
    /// Only the sweeping shell's own ids are swept: another shell's lists share the domain.
    func testDiscardAllKeepsTheNamedWindowsOtherShellsAndTheLegacyList() {
        defaults.set(legacy, forKey: WindowLocations.legacyKey)
        _ = WindowLocations.store(forWindow: "mac-live", isRestoredWindow: false, defaults: defaults)
        _ = WindowLocations.store(forWindow: "mac-dead", isRestoredWindow: false, defaults: defaults)
        _ = WindowLocations.store(forWindow: "scene-other", isRestoredWindow: false, defaults: defaults)
        WindowLocations.discardAll(except: ["mac-live"], idPrefix: "mac-", defaults: defaults)
        XCTAssertNotNil(defaults.object(forKey: WindowLocations.key(forWindow: "mac-live")))
        XCTAssertNil(defaults.object(forKey: WindowLocations.key(forWindow: "mac-dead")))
        XCTAssertNotNil(defaults.object(forKey: WindowLocations.key(forWindow: "scene-other")),
                        "another shell's list is not this shell's to sweep")
        XCTAssertNotNil(defaults.data(forKey: WindowLocations.legacyKey), "the legacy list is read-only")
    }
}

final class ExternalOpenRoutingTests: XCTestCase {
    func testFolderAlreadyShownComesForward() {
        let roots = [["/a"], ["/b", "/c"]]
        XCTAssertEqual(ExternalOpenRouting.windowShowing(folder: "/c", windowRoots: roots), 1)
        XCTAssertNil(ExternalOpenRouting.windowShowing(folder: "/c/sub", windowRoots: roots))
    }

    func testFileGoesToTheWindowWhoseFolderContainsIt() {
        let roots = [["/notes"], ["/papers"]]
        XCTAssertEqual(ExternalOpenRouting.windowContaining(file: "/papers/x.tex", windowRoots: roots), 1)
        XCTAssertNil(ExternalOpenRouting.windowContaining(file: "/other/x.md", windowRoots: roots))
    }

    func testDeepestRootWins() {
        let roots = [["/work"], ["/work/paper"]]
        XCTAssertEqual(
            ExternalOpenRouting.windowContaining(file: "/work/paper/main.tex", windowRoots: roots), 1)
    }

    func testTiesGoToTheFrontmostWindow() {
        let roots = [["/work"], ["/work"]]
        XCTAssertEqual(ExternalOpenRouting.windowContaining(file: "/work/a.md", windowRoots: roots), 0)
    }

    func testSiblingWithSharedPrefixIsNotInside() {
        XCTAssertNil(ExternalOpenRouting.windowContaining(file: "/notes2/a.md", windowRoots: [["/notes"]]))
    }

}
