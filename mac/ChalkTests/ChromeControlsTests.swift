import XCTest
import ChalkKit
@testable import Chalk

/// The chrome buttons still do their jobs, and none of them wedges the main
/// thread.
///
/// Paper moved every one of them into the floating pill and took the Library's
/// footer row away, so the wiring they run through changed at once.
///
/// The budget is deliberately loose: a freeze is seconds or forever, not
/// milliseconds, and a tight bound would only measure the machine's mood.
@MainActor
final class ChromeControlsTests: XCTestCase {
    private var window: NSWindow!
    private var root: RootSplitViewController!
    private var previousMode: EditingMode!
    /// The RAW persisted width, so restore can put back "never resized"
    /// rather than freezing today's default — this suite drives the sidebar,
    /// and `Preferences` is the OWNER's UserDefaults domain (see
    /// ChromeMatrixHost for the incident that established this rule).
    private var previousWidthRaw: Any?
    private static let sidebarWidthKey = Preferences.sidebarWidthKey

    override func setUp() {
        super.setUp()
        previousMode = Preferences.editingMode
        previousWidthRaw = UserDefaults.standard.object(forKey: Self.sidebarWidthKey)
        
        window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        root = RootSplitViewController()
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
        root.view.layoutIfNeeded()
    }

    override func tearDown() {
        Preferences.editingMode = previousMode
        if let raw = previousWidthRaw {
            UserDefaults.standard.set(raw, forKey: Self.sidebarWidthKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.sidebarWidthKey)
        }
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        root = nil
        super.tearDown()
    }

    /// `admitShellAction` coalesces same-selector dispatches inside a 0.3s
    /// window (one key press arrives over several paths); a deliberate second
    /// toggle has to sit outside it.
    private func outlastAdmitWindow() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
    }

    @discardableResult
    private func timed(_ what: String, _ body: () -> Void,
                       file: StaticString = #filePath, line: UInt = #line) -> TimeInterval {
        let start = Date()
        body()
        window.layoutIfNeeded()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "\(what) took \(elapsed)s on the main thread",
                          file: file, line: line)
        return elapsed
    }

    // MARK: - Every button in the pill

    func testTheSidebarToggleOpensAndClosesTheLibrary() {
        let state = UIState(window: .windowed,
                            sidebar: .shown, mode: .normal, appearance: .dark)
        let open = { self.root.chromeLayout(for: state).libraryPanel != nil }

        let before = open()
        timed("sidebar toggle") { self.root.cmdToggleSidebar(nil) }
        // The slide settles over its own clock.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertNotEqual(open(), before, "⌘B must actually move the Library")

        outlastAdmitWindow()
        timed("sidebar toggle back") { self.root.cmdToggleSidebar(nil) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertEqual(open(), before, "and put it back")
    }

    func testTheEditingModeButtonReachesEveryMode() {
        for mode in [EditingMode.zen, .typewriter, .focus, .normal] {
            timed("editing mode \(mode)") { self.root.setEditingMode(mode) }
            XCTAssertEqual(Preferences.editingMode, mode)
        }
    }

    /// The pill stands in every state, so its buttons are always reachable —
    /// which is the whole reason the Library's footer row could go away.
    func testThePillIsThereWithTheLibraryOpenAndClosed() {
        XCTAssertFalse(root.footerPillFrameForTesting.isEmpty)
        root.cmdToggleSidebar(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertFalse(root.footerPillFrameForTesting.isEmpty,
                       "hiding it in one state is what made it read as jumping")
        // Leave the shell as it was found: the next suite in the lane inherits
        // this process.
        outlastAdmitWindow()
        root.cmdToggleSidebar(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
    }
}
