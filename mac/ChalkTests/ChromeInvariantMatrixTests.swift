import XCTest
import ChalkKit
@testable import Chalk

/// Drives a real root into each state of the matrix and asserts
/// every invariant that is both applicable AND falsifiable there.
///
/// The second half of that sentence is the whole point. A rule that evaluates
/// to true because the geometry it inspects is absent is not a passing test,
/// it is a blind spot wearing a green tick, and this suite counts and names
/// them instead of averaging them into a total.
@MainActor
final class ChromeInvariantMatrixTests: XCTestCase {
    /// The window hosting, preference snapshot/restore, state configuration
    /// and settle discipline all live in `ChromeMatrixHost`, shared with the
    /// transition matrix; this suite owns only the invariant assertions.
    private var host: ChromeMatrixHost!

    override func setUp() {
        super.setUp()
        host = ChromeMatrixHost()
    }

    override func tearDown() {
        host.restoreAndDismantle()
        host = nil
        super.tearDown()
    }

    /// Fails when a PREVIOUS run leaked a mode into the real preferences.
    ///
    /// Zen is never the value a machine sits in by default, so finding it here
    /// at the start of a run means an earlier run died before restoring. Better
    /// to say so in a test than to let the owner discover it as a broken app.
    func testTheSuiteDidNotLeakAnEditingModeLastTime() {
        XCTAssertNotEqual(host.incomingEditingMode, .zen,
                          "a previous run left editingMode = zen in UserDefaults.standard, "
                        + "which the real app reads; it launches with no tab band until reset")
    }

    private func root(in state: UIState) -> RootSplitViewController {
        let root = host.makeRoot(for: state)
        // Settled to the FIXED POINT before anything reads geometry: the
        // split view finishes its tiling over runloop turns, and a fixed
        // turn count was measured not to be reliably enough (see
        // ChromeMatrixHost.settleToFixedPoint).
        if !host.settleToFixedPoint(root, state: state) {
            XCTFail("\(state.id): the layout never reached a fixed point over 10 settle turns")
        }
        return root
    }

    /// Every way a state's configuration can fail to take, checked against the
    /// chrome rather than against the flags that were set.
    ///
    /// A matrix whose cells silently collapse into each other is worse than no
    /// matrix: it reports 32 passes for a handful of distinct layouts. These
    /// are the observable consequences of the four dimensions this suite
    /// drives, so a cell that did not configure says so by name.
    private func configurationFaults(
        _ state: UIState, _ layout: ChromeLayout, _ controller: RootSplitViewController
    ) -> [String] {
        var faults: [String] = []
        if state.mode == .zen {
            if !controller.isHeaderHiddenForTesting {
                faults.append("\(state.id): zen was requested but the tab band is still shown")
            }
            if layout.libraryPanel != nil {
                faults.append("\(state.id): zen was requested but the Library is still open "
                              + "(applyZenChrome's Library hide did not run)")
            }
        } else if state.sidebar == .shown && layout.libraryPanel == nil {
            faults.append("\(state.id): the Library was requested and is not open")
        }
        if state.sidebar == .hidden && layout.libraryPanel != nil {
            faults.append("\(state.id): the Library was not requested and is open")
        }
        if state.mode == .zen {
            if layout.outlinePanel != nil {
                faults.append("\(state.id): zen was requested but the outline panel is still open")
            }
        } else if state.outline == .shown && layout.outlinePanel == nil {
            faults.append("\(state.id): the outline panel was requested and is not open")
        }
        if state.outline == .hidden && layout.outlinePanel != nil {
            faults.append("\(state.id): the outline panel was not requested and is open")
        }
        // The dimension only exists if the chrome actually swaps. Without the
        // glue, `applyMacChromePresentation` returns early and the cell is a
        // windowed duplicate — which must be stated, not absorbed.
        if state.window == .fullscreen && state.mode == .normal && layout.band.isEmpty {
            faults.append("""
                \(state.id): full screen was requested and the UIKit band is not hosted, \
                so this cell does NOT exercise full screen (AppKit glue available: \
                \(controller.isAppKitGlueAvailableForTesting))
                """)
        }
        return faults
    }

    func testEveryInvariantHoldsInEveryState() {
        let previousMode = Preferences.editingMode
        defer { Preferences.editingMode = previousMode }

        var failures: [String] = []
        var configFaults: [String] = []
        // Per-state count of FALSIFIABLE assertions: applicable, and evaluated
        // against geometry that could have come out differently. Applicability
        // alone was not enough — `chromeStaysInsideTheWindow` applies to every
        // state and reduces to `root.contains(nothing)` when the chrome is
        // absent, so every state scored at least 1 by construction and the
        // guard below could never fire (finding 2 of the 2026-08-19 review).
        var coverage: [(id: String, names: [String])] = []
        var records: [ChromeLayoutRecord] = []
        for state in UIState.matrix {
            let controller = root(in: state)
            let layout = controller.chromeLayout(for: state)
            configFaults += configurationFaults(state, layout, controller)
            records.append(ChromeLayoutRecord(layout, scale: ChalkMetrics.displayScale))

            var asserted: [String] = []
            for invariant in ChromeInvariant.catalogue
            where invariant.isEvidence(about: layout) {
                asserted.append(invariant.name)
                if !invariant.holds(layout) {
                    failures.append("""
                        \(state.id): \(invariant.name)
                          \(invariant.rationale)
                          root=\(layout.root) band=\(layout.band) paint=\(layout.bandPaint)
                          hole=\(String(describing: layout.bandPaintHole)) \
                        panel=\(String(describing: layout.libraryPanel)) \
                        chips=\(layout.tabStrip) resting=\(layout.editorRestingTop)
                          pill=\(layout.footerPill) corner=\(layout.pillCorner) \
                        content=\(layout.editorContent) reserve=\(layout.reserveTop) \
                        safeLeading=\(layout.safeLeading)
                          chip=\(String(describing: layout.activeChip)) \
                        strip=\(String(describing: layout.macStrip))
                        """)
                }
            }
            coverage.append((state.id, asserted))
        }

        let counts = coverage.map(\.names.count)
        print("""
            ChromeInvariantMatrixTests falsifiable coverage \
            (\(coverage.count) states, min \(counts.min() ?? 0), max \(counts.max() ?? 0)):
            """)
        for entry in coverage {
            let names = entry.names.isEmpty ? "-" : entry.names.joined(separator: ", ")
            print("  \(entry.id): \(entry.names.count)  \(names)")
        }

        // Appearance is a colour dimension. If light and dark siblings assert
        // different NUMBERS of invariants, something about the geometry moved
        // with the palette — or, as happened here, the states were order
        // dependent and the second of the pair was configured differently.
        var siblings: [String: [(id: String, count: Int)]] = [:]
        for entry in coverage {
            let key = entry.id.split(separator: "-").dropLast().joined(separator: "-")
            siblings[key, default: []].append((entry.id, entry.names.count))
        }
        let uneven = siblings.values
            .filter { Set($0.map(\.count)).count > 1 }
            .map { pair in pair.map { "\($0.id)=\($0.count)" }.joined(separator: " vs ") }
            .sorted()
        XCTAssertTrue(uneven.isEmpty,
                      "appearance changed how much geometry could be asserted, which means it "
                      + "changed the geometry or the configuration: " + uneven.joined(separator: "; "))

        XCTAssertTrue(configFaults.isEmpty,
                      "\(configFaults.count) state(s) did not configure as asked:\n"
                      + configFaults.joined(separator: "\n"))

        // No averaging, no leniency: a state that can falsify nothing is
        // reported by name. Passing this guard by lowering it would recreate
        // exactly the failure it exists to expose.
        let blind = coverage.filter { $0.names.isEmpty }.map(\.id)
        XCTAssertTrue(blind.isEmpty,
                      "\(blind.count) of \(coverage.count) state(s) assert NOTHING falsifiable "
                      + "(a blind spot, not a pass): " + blind.joined(separator: ", "))

        XCTAssertTrue(failures.isEmpty,
                      "\(failures.count) invariant violation(s):\n" + failures.joined(separator: "\n\n"))

        writeReferenceIfRequested(records)
    }

    /// The AppKit port's reference (plan: "UI parity method"): every cell's
    /// layout in Mac points, written when the runner sets
    /// `TEST_RUNNER_CHALK_CHROME_REFERENCE_OUT=<path>`. Off otherwise, so the
    /// suite never writes into the repo on its own.
    private func writeReferenceIfRequested(_ records: [ChromeLayoutRecord]) {
        guard let path = ProcessInfo.processInfo.environment["CHALK_CHROME_REFERENCE_OUT"],
              !path.isEmpty else { return }
        let today = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let reference = ChromeLayoutReference(shell: "catalyst", captured: today, cells: records)
        do {
            try reference.encoded().write(to: URL(fileURLWithPath: path))
        } catch {
            XCTFail("could not write the chrome reference to \(path): \(error)")
        }
    }

    /// The matrix is worthless if the states do not actually differ. This
    /// catches a root that silently ignored the configuration.
    func testStatesProduceDistinctLayouts() {
        // `root(in:)` writes `Preferences.editingMode`, which is UserDefaults
        // and therefore outlives the test. Leaking `.zen` into whatever runs
        // next is how the matrix became order dependent in the first place.
        let previousMode = Preferences.editingMode
        defer { Preferences.editingMode = previousMode }

        let states = UIState.matrix
        let withSidebar = states.first { $0.sidebar == .shown && $0.mode == .normal }!
        let without = states.first { $0.sidebar == .hidden && $0.mode == .normal }!
        XCTAssertNotNil(root(in: withSidebar).chromeLayout(for: withSidebar).libraryPanel)
        XCTAssertNil(root(in: without).chromeLayout(for: without).libraryPanel)

        // `setEditingMode(.zen)` must observably change the chrome too, or the
        // zen half of the matrix is configured but silently inert — every
        // zen state would report a layout indistinguishable from normal.
        //
        // `ChromeLayout` is `Equatable` over EVERY stored property, including
        // `state` — and `chromeLayout(for:)` embeds the argument it was
        // called with verbatim. Comparing the whole struct would make this
        // pass on the enum alone (`.normal` != `.zen`) even if `setEditingMode`
        // moved nothing, so this compares only the GEOMETRIC fields:
        // everything chrome invariants actually read, minus `state` (not
        // geometry) and `root`/`restingPad` (window size and a constant,
        // neither of which zen touches, so including them would only ever
        // add always-equal noise, never signal).
        let zenTwin = states.first {
            $0.window == withSidebar.window && $0.sidebar == withSidebar.sidebar
                && $0.appearance == withSidebar.appearance && $0.mode == .zen
        }!
        let normalLayout = root(in: withSidebar).chromeLayout(for: withSidebar)
        let zenLayout = root(in: zenTwin).chromeLayout(for: zenTwin)
        let geometryDiffers = normalLayout.band != zenLayout.band
            || normalLayout.bandPaint != zenLayout.bandPaint
            || normalLayout.bandPaintHole != zenLayout.bandPaintHole
            || normalLayout.libraryPanel != zenLayout.libraryPanel
            || normalLayout.tabStrip != zenLayout.tabStrip
            || normalLayout.editorRestingTop != zenLayout.editorRestingTop
        XCTAssertTrue(geometryDiffers,
                      "setEditingMode(.zen) must observably change the chrome GEOMETRY, "
                      + "not just UIState.mode: normal=\(normalLayout) zen=\(zenLayout)")
    }
}
