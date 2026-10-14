import XCTest
import ChalkKit
@testable import Chalk

/// The chrome buttons still do their jobs, and none of them wedges the main
/// thread.
///
/// Paper moved every one of them into the floating pill and took the Library's
/// footer row away, so the wiring they run through changed at once. It also
/// put writes inside the Library's layout pass (the tree's clearance, the
/// measured list trim) — and a
/// layout write that re-derives its own input is how an app freezes with the
/// sidebar open, which is exactly what the owner asked to be sure of.
///
/// The budget is deliberately loose: a freeze is seconds or forever, not
/// milliseconds, and a tight bound would only measure the machine's mood.
@MainActor
final class ChromeControlsTests: XCTestCase {
    private var window: UIWindow!
    private var root: RootSplitViewController!
    private var previousMode: EditingMode!
    /// The RAW persisted width, so restore can put back "never resized"
    /// rather than freezing today's default — this suite drives the sidebar,
    /// and `Preferences` is the OWNER's UserDefaults domain (see
    /// ChromeMatrixHost for the incident that established this rule).
    private var previousWidthRaw: Any?
    private static let sidebarWidthKey = "chalk.sidebarWidth"

    override func setUp() {
        super.setUp()
        previousMode = Preferences.editingMode
        previousWidthRaw = UserDefaults.standard.object(forKey: Self.sidebarWidthKey)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first!
        window = UIWindow(windowScene: scene)
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
        timed("sidebar toggle") { self.root.cmdToggleSidebar() }
        // The slide settles over its own clock.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertNotEqual(open(), before, "⌘B must actually move the Library")

        outlastAdmitWindow()
        timed("sidebar toggle back") { self.root.cmdToggleSidebar() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertEqual(open(), before, "and put it back")
    }

    func testQuickOpenAndTheOutlineOpenAndClose() {
        timed("quick open") { self.root.cmdQuickOpen() }
        XCTAssertTrue(root.isQuickOpenVisibleForTesting)
        outlastAdmitWindow()
        timed("quick open again") { self.root.cmdQuickOpen() }
        XCTAssertFalse(root.isQuickOpenVisibleForTesting)

        outlastAdmitWindow()
        timed("outline") { self.root.cmdToggleOutline() }
        XCTAssertTrue(root.isOutlineVisibleForTesting)
        outlastAdmitWindow()
        timed("outline again") { self.root.cmdToggleOutline() }
        XCTAssertFalse(root.isOutlineVisibleForTesting)
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
        root.cmdToggleSidebar()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertFalse(root.footerPillFrameForTesting.isEmpty,
                       "hiding it in one state is what made it read as jumping")
        // Leave the shell as it was found: the next suite in the lane inherits
        // this process.
        outlastAdmitWindow()
        root.cmdToggleSidebar()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
    }

    // MARK: - The appearance the AppKit chrome adopts

    /// The glue's colours resolve against the WINDOW's NSAppearance, which
    /// follows the SYSTEM appearance until someone sets it — so an app forced
    /// to Light on a dark Mac painted the titlebar's cover in the dark tone.
    /// The app tells the glue which appearance it is in; this pins WHAT it
    /// tells it (the glue's own half lives in a bundle no test target links,
    /// exactly like the strip contract).
    func testTheAppTellsTheGlueWhichAppearanceItIsIn() throws {
        let previousTheme = Preferences.themePreference
        defer { Preferences.themePreference = previousTheme }

        var posted: [String] = []
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name("chalk.window.appearance"), object: nil, queue: nil
        ) { note in
            if let style = note.userInfo?["style"] as? String { posted.append(style) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let cases: [(ThemePreference, String)] = [(.dark, "dark"), (.light, "light"), (.auto, "system")]
        for (preference, expected) in cases {
            Preferences.themePreference = preference
            root.pushAppearanceToGlue()
            XCTAssertEqual(posted.last, expected,
                           "\(preference) must reach the glue as \(expected)")
        }
    }

    /// NSAppearance carries no theme, so the theme rides the same post.
    func testTheAppTellsTheGlueWhichThemeItIsIn() throws {
        let previousTheme = Preferences.colorTheme
        defer { Preferences.colorTheme = previousTheme }

        var posted: [String] = []
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name("chalk.window.appearance"), object: nil, queue: nil
        ) { note in
            if let theme = note.userInfo?["theme"] as? String { posted.append(theme) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        for theme in ChalkTheme.allCases {
            Preferences.colorTheme = theme
            root.pushAppearanceToGlue()
            XCTAssertEqual(posted.last, theme.rawValue, "\(theme) must reach the glue")
        }
    }

    // MARK: - The Library's own layout does not chase itself

    /// Three writes now happen inside the Library's layout pass. Each one is
    /// guarded, but the guards only matter together: run the pass repeatedly
    /// and every number it writes must stop moving.
    func testRepeatedLayoutPassesReachAFixedPoint() {
        let sidebar = root.sidebarForTesting
        sidebar.loadViewIfNeeded()
        let list = sidebar.collectionViewForTesting
        window.layoutIfNeeded()
        let panel = sidebar.panelFrameForTesting
        let clearance = sidebar.treeTopClearance()
        let inset = list.contentInset.top

        for pass in 1...6 {
            sidebar.view.setNeedsLayout()
            root.view.setNeedsLayout()
            window.layoutIfNeeded()
            XCTAssertEqual(sidebar.panelFrameForTesting, panel,
                           "pass \(pass): the panel moved again")
            XCTAssertEqual(sidebar.treeTopClearance(), clearance, accuracy: 0.5,
                           "pass \(pass): the tree's top moved again")
            XCTAssertEqual(list.contentInset.top, inset, accuracy: 0.5,
                           "pass \(pass): the list trim moved again")
        }
    }

    /// A chrome floor answered over and over (every layout pass asks) must
    /// not accumulate: the same floor is the same clearance.
    func testRepeatedTreeTopAnswersAreIdempotent() {
        let sidebar = root.sidebarForTesting
        sidebar.loadViewIfNeeded()
        sidebar.treeTopProvider = { 80 }
        sidebar.view.setNeedsLayout()
        window.layoutIfNeeded()
        let clearance = sidebar.treeTopClearance()

        for _ in 1...5 {
            sidebar.view.setNeedsLayout()
            window.layoutIfNeeded()
        }
        XCTAssertEqual(sidebar.treeTopClearance(), clearance, accuracy: 0.5)
    }
}
