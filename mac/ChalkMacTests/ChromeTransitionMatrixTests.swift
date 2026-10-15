import XCTest
import ChalkKit
@testable import ChalkMac

/// The chrome's TRANSITIONS, asserted against the same truth as its resting
/// states: after any sequence of user-level toggles, the settled layout must
/// be field-for-field the layout a FRESH root shows for that state. The
/// invariant matrix proves each state is right in isolation; this suite
/// proves no path BETWEEN states leaves hysteresis behind: a stale inset, a
/// parked column, a chrome element that only some history restores.
///
/// Every step runs through the REAL entry points (`applyTransitionForTesting`
/// bypasses only the key-press coalescer), under the `.instant` motion policy
/// so a settle is two runloop turns instead of an animation clock. The
/// expected state after each step comes from `UIState.applying(_:)`, the
/// written-down product rules.
@MainActor
final class ChromeTransitionMatrixTests: XCTestCase {
    private var host: ChromeMatrixHost!

    /// Pinned for the whole suite (and restored by the host): the fresh
    /// layouts this suite compares against are cached across tests, so the
    /// sidebar width must be the same number in every one of them.
    private static let pinnedSidebarWidth: CGFloat = 300

    override func setUp() {
        super.setUp()
        host = ChromeMatrixHost()
        Preferences.sidebarWidth = Self.pinnedSidebarWidth
    }

    override func tearDown() {
        host.restoreAndDismantle()
        host = nil
        super.tearDown()
    }

    // MARK: - Fresh-state oracle

    /// One fresh, settled layout per state, computed once per run. Keyed by
    /// state id; safe to cache across tests because the sidebar width is
    /// pinned to the same value in every setUp.
    private static var freshLayouts: [String: ChromeLayout] = [:]

    private func freshLayout(for state: UIState) -> ChromeLayout {
        if let cached = Self.freshLayouts[state.id] { return cached }
        let root = host.makeRoot(for: state)
        root.motionPolicyForTesting = .instant
        // The oracle gets the SAME settle as the paths it will be compared
        // against, and a stricter one than the resting-state suites need: this
        // layout is cached for the whole run, so a cell captured one turn early
        // is every later comparison against that cell.
        host.settleToFixedPoint(root, state: state, budget: 2.0, stableTurns: 3) { root in
            root.isSidebarVisible == (state.sidebar == .shown)
                && root.isOutlinePanelVisibleForTesting == (state.outline == .shown)
        }
        let layout = root.chromeLayout(for: state)
        Self.freshLayouts[state.id] = layout
        return layout
    }

    /// Fill the whole cache BEFORE hosting a root under test: building a
    /// fresh layout re-points the window's content, which would evict the
    /// root a path is being driven on.
    private func warmFreshLayouts() {
        for state in startStates { _ = freshLayout(for: state) }
    }

    // MARK: - Comparing layouts

    private func rectsDiffer(_ a: CGRect, _ b: CGRect, by tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) > tolerance || abs(a.minY - b.minY) > tolerance
            || abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance
    }

    private func optionalRectsDiffer(_ a: CGRect?, _ b: CGRect?, by tolerance: CGFloat) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case let (a?, b?): return rectsDiffer(a, b, by: tolerance)
        default: return true
        }
    }

    private func optionalValuesDiffer(_ a: CGFloat?, _ b: CGFloat?, by tolerance: CGFloat) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case let (a?, b?): return abs(a - b) > tolerance
        default: return true
        }
    }

    /// Field-by-field comparison at 1pt tolerance; names every field that
    /// differs so a failure reads as a diagnosis, not a diff dump.
    private func mismatches(_ reached: ChromeLayout, _ fresh: ChromeLayout) -> [String] {
        let t: CGFloat = 1.0
        var out: [String] = []
        func rect(_ name: String, _ a: CGRect, _ b: CGRect) {
            if rectsDiffer(a, b, by: t) { out.append("\(name): reached=\(a) fresh=\(b)") }
        }
        func optRect(_ name: String, _ a: CGRect?, _ b: CGRect?) {
            if optionalRectsDiffer(a, b, by: t) {
                out.append("\(name): reached=\(String(describing: a)) fresh=\(String(describing: b))")
            }
        }
        func value(_ name: String, _ a: CGFloat, _ b: CGFloat) {
            if abs(a - b) > t { out.append("\(name): reached=\(a) fresh=\(b)") }
        }
        rect("root", reached.root, fresh.root)
        rect("band", reached.band, fresh.band)
        rect("bandPaint", reached.bandPaint, fresh.bandPaint)
        optRect("bandPaintHole", reached.bandPaintHole, fresh.bandPaintHole)
        optRect("libraryPanel", reached.libraryPanel, fresh.libraryPanel)
        rect("tabStrip", reached.tabStrip, fresh.tabStrip)
        value("editorRestingTop", reached.editorRestingTop, fresh.editorRestingTop)
        rect("footerPill", reached.footerPill, fresh.footerPill)
        rect("editorContent", reached.editorContent, fresh.editorContent)
        value("reserveTop", reached.reserveTop, fresh.reserveTop)
        value("safeLeading", reached.safeLeading, fresh.safeLeading)
        if optionalValuesDiffer(reached.libraryFirstRowTop, fresh.libraryFirstRowTop, by: t) {
            out.append("libraryFirstRowTop: reached=\(String(describing: reached.libraryFirstRowTop)) "
                       + "fresh=\(String(describing: fresh.libraryFirstRowTop))")
        }
        if optionalValuesDiffer(reached.libraryScrollOffset, fresh.libraryScrollOffset, by: t) {
            out.append("libraryScrollOffset: reached=\(String(describing: reached.libraryScrollOffset)) "
                       + "fresh=\(String(describing: fresh.libraryScrollOffset))")
        }
        optRect("activeChip", reached.activeChip, fresh.activeChip)
        optRect("outlinePanel", reached.outlinePanel, fresh.outlinePanel)
        optRect("bandPaintTrailingHole", reached.bandPaintTrailingHole, fresh.bandPaintTrailingHole)
        if reached.outlinePanelIsOverlay != fresh.outlinePanelIsOverlay {
            out.append("outlinePanelIsOverlay: reached=\(reached.outlinePanelIsOverlay) "
                       + "fresh=\(fresh.outlinePanelIsOverlay)")
        }
        return out
    }

    // MARK: - Driving steps

    /// Apply one toggle through the real entry points, settle, and return
    /// every complaint: configuration faults, invariant violations, and
    /// fresh-layout mismatches, tagged with the path so the failure names
    /// the history that produced it.
    private func applyAndAudit(
        _ step: TransitionStep, on root: RootSplitViewController,
        state: inout UIState, path: String
    ) -> [String] {
        let expected = state.applying(step)
        if case .window = step {
            // A window-mode change is a window-size change plus the
            // full-screen chrome flag the window would flip.
            host.window.frame = CGRect(origin: .zero, size: ChromeMatrixHost.size(for: expected))
        }
        root.applyTransitionForTesting(step)
        state = expected
        // Settle to the fixed point OF THE EXPECTED STATE, not merely to a
        // still layout; the budget only costs time when a step has not landed.
        host.settle(root, state: state, budget: 2.0, stableTurns: 3) { root in
            root.isSidebarVisible == (expected.sidebar == .shown)
                && root.isOutlinePanelVisibleForTesting == (expected.outline == .shown)
        }

        var complaints: [String] = []
        let layout = root.chromeLayout(for: state)

        // Configuration first: a step that did not take makes every further
        // assertion about the wrong state.
        if root.isSidebarVisible != (expected.sidebar == .shown) {
            complaints.append("\(path): the Library is \(root.isSidebarVisible ? "shown" : "hidden"), "
                              + "expected \(expected.sidebar.rawValue)")
        }

        let outlineShown = root.isOutlinePanelVisibleForTesting
        if outlineShown != (expected.outline == .shown) {
            complaints.append("\(path): outline panel \(outlineShown ? "shown" : "hidden"), "
                              + "expected \(expected.outline.rawValue)")
        }

        for invariant in ChromeInvariant.catalogue where invariant.isEvidence(about: layout) {
            if !invariant.holds(layout) {
                complaints.append("\(path): invariant \(invariant.name)\n    \(invariant.rationale)")
            }
        }

        for mismatch in mismatches(layout, freshLayout(for: expected)) {
            complaints.append("\(path): differs from the fresh \(expected.id) layout: \(mismatch)")
        }
        return complaints
    }

    /// The four user toggles, each phrased as "flip this dimension" relative
    /// to `state`.
    private func flip(_ dimension: Int, of state: UIState) -> TransitionStep {
        switch dimension {
        case 0: return .sidebar(state.sidebar == .hidden)
        case 1: return .window(state.window == .windowed ? .fullscreen : .windowed)
        case 2: return .zen(state.mode == .normal)
        default: return .outline(state.outline == .hidden)
        }
    }

    /// The light cells: appearance is a colour dimension and transitions do
    /// not touch it. Zen cells are NORMALIZED to sidebar-hidden and
    /// deduplicated: the matrix's `zen + sidebar-shown` id is a CONFIGURATION
    /// (open the Library, then enter zen), but the state it produces holds
    /// the Library closed, which is `UIState.applying`'s zen rule.
    private var startStates: [UIState] {
        var seen = Set<String>()
        return UIState.matrix
            .filter { $0.appearance == .light }
            .map { state in
                state.mode == .zen ? state.applying(.zen(true)) : state
            }
            .filter { seen.insert($0.id).inserted }
    }

    private func makeStartRoot(_ state: UIState) -> RootSplitViewController {
        let root = host.makeRoot(for: state)
        root.motionPolicyForTesting = .instant
        host.settleToFixedPoint(root, state: state)
        return root
    }

    // MARK: - The matrix

    func testEverySingleToggleAndItsInverseLandsOnTheFreshState() {
        warmFreshLayouts()
        var complaints: [String] = []
        for start in startStates {
            for dimension in 0..<4 {
                let root = makeStartRoot(start)
                var state = start
                let first = flip(dimension, of: state)
                complaints += applyAndAudit(first, on: root, state: &state,
                                            path: "\(start.id) -> \(first)")
                let inverse = flip(dimension, of: state)
                complaints += applyAndAudit(inverse, on: root, state: &state,
                                            path: "\(start.id) -> \(first) -> \(inverse)")
            }
        }
        XCTAssertTrue(complaints.isEmpty,
                      "\(complaints.count) transition complaint(s):\n"
                      + complaints.joined(separator: "\n\n"))
    }

    func testEveryOrderedPairOfTogglesAndItsInversePairLandsOnTheFreshState() {
        warmFreshLayouts()
        var complaints: [String] = []
        for start in startStates {
            for a in 0..<4 {
                for b in 0..<4 where a != b {
                    let root = makeStartRoot(start)
                    var state = start
                    var path = start.id
                    // The pair, then the inverse pair in reverse order; each
                    // flip is computed against the state it actually finds.
                    for dimension in [a, b, b, a] {
                        let step = flip(dimension, of: state)
                        path += " -> \(step)"
                        complaints += applyAndAudit(step, on: root, state: &state, path: path)
                    }
                }
            }
        }
        XCTAssertTrue(complaints.isEmpty,
                      "\(complaints.count) transition complaint(s):\n"
                      + complaints.joined(separator: "\n\n"))
    }

    // MARK: - Named regressions

    /// Seed the Library with enough real rows to scroll, without touching the
    /// owner's LocationStore.
    private func seedScrollableLibrary(on root: RootSplitViewController) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-transition-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for index in 0..<60 {
            let file = dir.appendingPathComponent(String(format: "note-%02d.md", index))
            try "# note \(index)\n".write(to: file, atomically: true, encoding: .utf8)
        }
        root.setLibraryLocationsForTesting([dir])
        host.settle(root)
        return dir
    }

    /// 2026-08-23 polish night, the reader's complaint behind this suite: a
    /// full-screen round trip must hand the Library back exactly where it
    /// was, scroll position included.
    func testFullscreenRoundTripKeepsTheLibraryWhereItWas() throws {
        warmFreshLayouts()
        let start = UIState(window: .windowed, sidebar: .shown,
                            mode: .normal, appearance: .light)
        let root = makeStartRoot(start)
        let dir = try seedScrollableLibrary(on: root)
        defer { try? FileManager.default.removeItem(at: dir) }

        root.setLibraryScrollOffsetForTesting(120)
        host.settle(root, state: start)
        let before = root.chromeLayout(for: start)
        XCTAssertEqual(before.libraryScrollOffset ?? -1, 120, accuracy: 1.0,
                       "the seed must actually scroll, or the round trip proves nothing")
        let beforeFirstRow = try XCTUnwrap(before.libraryFirstRowTop)

        var state = start
        var complaints = applyAndAudit(.window(.fullscreen), on: root, state: &state,
                                       path: "\(start.id) -> window(fullscreen)")
        // The library fields are excluded from the fresh comparison here by
        // construction (the fresh root has no Library content, this one has
        // the seeded one), so drop those complaints and assert the round
        // trip directly instead.
        complaints = complaints.filter { !$0.contains("libraryFirstRowTop") && !$0.contains("libraryScrollOffset") && !$0.contains("activeChip") }

        host.window.frame = CGRect(origin: .zero, size: ChromeMatrixHost.size(for: start))
        root.applyTransitionForTesting(.window(.windowed))
        host.settle(root, state: start)

        let after = root.chromeLayout(for: start)
        XCTAssertEqual(after.libraryScrollOffset ?? -1, 120, accuracy: 1.0,
                       "a full-screen round trip moved the Library's scroll position")
        XCTAssertEqual(after.libraryFirstRowTop ?? -1, beforeFirstRow, accuracy: 1.0,
                       "a full-screen round trip moved the Library's first row")
        XCTAssertTrue(complaints.isEmpty, complaints.joined(separator: "\n\n"))
    }

    /// Zen borrows the whole window; handing it back and reopening the
    /// Library must land on the fresh tiled layout, not a zen-flavored one.
    func testZenEnterWithLibraryOpenThenExitRestoresTheColumn() {
        warmFreshLayouts()
        let start = UIState(window: .windowed, sidebar: .shown,
                            mode: .normal, appearance: .light)
        let root = makeStartRoot(start)
        var state = start
        var complaints: [String] = []
        for step in [TransitionStep.zen(true), .zen(false), .sidebar(true)] {
            complaints += applyAndAudit(step, on: root, state: &state,
                                        path: "\(start.id) -> \(step)")
        }
        XCTAssertEqual(state, start, "the round trip should end where it began")
        XCTAssertTrue(complaints.isEmpty,
                      "\(complaints.count) complaint(s):\n" + complaints.joined(separator: "\n\n"))
    }

    /// A rapid re-toggle lands mid-transition by design; landing CLEANLY is
    /// the contract (docs/motion.md: a canceled transition rewinds cleanly).
    func testRapidDoubleToggleLandsCleanly() {
        warmFreshLayouts()
        let start = UIState(window: .windowed, sidebar: .hidden,
                            mode: .normal, appearance: .light)
        let root = makeStartRoot(start)
        // Three toggles in ONE turn: no settle between them.
        root.applyTransitionForTesting(.sidebar(true))
        root.applyTransitionForTesting(.sidebar(false))
        root.applyTransitionForTesting(.sidebar(true))
        let shown = start.applying(.sidebar(true))
        host.settle(root, state: shown)
        XCTAssertFalse(root.isSidebarTransitionInFlightForTesting,
                       "the slide machinery must not still own state after the settle")
        let found = mismatches(root.chromeLayout(for: shown), freshLayout(for: shown))
        XCTAssertTrue(found.isEmpty,
                      "rapid toggling left the chrome unlike a fresh shown state:\n"
                      + found.joined(separator: "\n"))
    }

    /// Resizing with the Library open re-tiles both columns; coming back to
    /// the original size must land on the fresh layout for it.
    func testWindowResizeWhileLibraryShown() {
        warmFreshLayouts()
        let start = UIState(window: .windowed, sidebar: .shown,
                            mode: .normal, appearance: .light)
        let root = makeStartRoot(start)
        let original = ChromeMatrixHost.size(for: start)
        host.window.frame = CGRect(origin: .zero,
                                   size: CGSize(width: original.width - 300,
                                                height: original.height - 100))
        host.settle(root, state: start)
        host.window.frame = CGRect(origin: .zero, size: original)
        host.settle(root, state: start)
        let found = mismatches(root.chromeLayout(for: start), freshLayout(for: start))
        XCTAssertTrue(found.isEmpty,
                      "a resize round trip left the chrome unlike a fresh layout:\n"
                      + found.joined(separator: "\n"))
    }
}
