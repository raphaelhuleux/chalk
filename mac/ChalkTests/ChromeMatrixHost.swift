import XCTest
import ChalkKit
@testable import Chalk

/// Shared harness for the chrome matrix suites (`ChromeInvariantMatrixTests`,
/// `ChromeTransitionMatrixTests`): one place that knows how to host a real
/// root in a real window, drive it into a `UIState`, and settle the layout
/// before anything reads geometry.
///
/// Extracted rather than duplicated because every rule here was paid for
/// once: the window hosting (safe areas only resolve in a window), the
/// preference snapshot/restore (an interrupted run must not leave the
/// OWNER'S app in zen), the pre-configuration ordering (zen only after the
/// window has real geometry), and the settle (the split view finishes its
/// tiling over runloop turns, not inside `layoutIfNeeded`).
@MainActor
final class ChromeMatrixHost {
    /// Reused across every state so root construction can stay a pure
    /// factory. Window-hosted, because the macOS 27 sidebar carve arrives
    /// through the secondary column's SAFE AREA, and safe areas only resolve
    /// inside a window (the same reason `FooterPillPlacementTests` and
    /// `HeaderBandTests` host one): the divider `applyBandLayout()` feeds to
    /// `BandLayout.resolve` is measured by `measuredBandInputs()`, which reads
    /// exactly that safe area, so an unhosted root reports the chips at the
    /// window's raw leading edge no matter what the sidebar is doing.
    let window: NSWindow

    /// The editing mode as the machine had it before the suite ran.
    ///
    /// `Preferences` is backed by `UserDefaults.standard`, which every suite
    /// and Debug launch shares, and a leaked zen hides the tab band and the
    /// Library. Snapshotting here and restoring in `tearDown` closes the case
    /// where a test throws; a killed process can still leak, which is why
    /// `PreferencePollutionGuardTests` catches it on the next run.
    let incomingEditingMode: EditingMode

    /// The RAW persisted sidebar width (nil when the user never resized), so
    /// restore can put back "unset" rather than freezing today's default.
    /// Suites that drive sidebar geometry pin `Preferences.sidebarWidth` to a
    /// fixed value; this snapshot is what makes that pin safe on the owner's
    /// machine.
    private let incomingSidebarWidthRaw: Any?
    private static let sidebarWidthKey = Preferences.sidebarWidthKey

    /// Same reasoning as `incomingSidebarWidthRaw`, for the outline panel's
    /// pinned width.
    private let incomingOutlinePanelWidthRaw: Any?
    private static let outlinePanelWidthKey = Preferences.outlinePanelWidthKey
    /// And for the slot's width while it shows the PDF.
    private let incomingPDFPanelWidthRaw: Any?
    private static let pdfPanelWidthKey = Preferences.pdfPanelWidthKey

    /// One folder with one file, so every Library-open cell has a first area
    /// header to measure: `libraryListStartsAtTheChromeFloor` is evidence only
    /// against a measured header, and a detached root's Library is empty.
    private let libraryFolder: URL

    init() {
        libraryFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-matrix-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
        try? Data("# note\n".utf8).write(to: libraryFolder.appendingPathComponent("note.md"))
        incomingEditingMode = Preferences.editingMode
        incomingSidebarWidthRaw = UserDefaults.standard.object(forKey: Self.sidebarWidthKey)
        incomingOutlinePanelWidthRaw = UserDefaults.standard.object(forKey: Self.outlinePanelWidthKey)
        UserDefaults.standard.removeObject(forKey: Self.outlinePanelWidthKey)
        incomingPDFPanelWidthRaw = UserDefaults.standard.object(forKey: Self.pdfPanelWidthKey)
        UserDefaults.standard.removeObject(forKey: Self.pdfPanelWidthKey)
        window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        window.isHidden = false
    }

    /// Restore everything the suite may have written; call from tearDown.
    func restoreAndDismantle() {
        Preferences.editingMode = incomingEditingMode
        if let raw = incomingSidebarWidthRaw {
            UserDefaults.standard.set(raw, forKey: Self.sidebarWidthKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.sidebarWidthKey)
        }
        if let raw = incomingOutlinePanelWidthRaw {
            UserDefaults.standard.set(raw, forKey: Self.outlinePanelWidthKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.outlinePanelWidthKey)
        }
        if let raw = incomingPDFPanelWidthRaw {
            UserDefaults.standard.set(raw, forKey: Self.pdfPanelWidthKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.pdfPanelWidthKey)
        }
        window.isHidden = true
        window.rootViewController = nil
        try? FileManager.default.removeItem(at: libraryFolder)
    }

    /// Windowed and fullscreen differ in size here; the size is not enough
    /// on its own (see `setMacFullscreenForTesting`), so `makeRoot` drives the
    /// chrome flag too.
    static func size(for state: UIState) -> CGSize {
        switch state.window {
        case .windowed:   return CGSize(width: 1200, height: 800)
        case .fullscreen: return CGSize(width: 1728, height: 1080)
        }
    }

    /// A fresh root, configured into `state` and laid out, NOT yet settled:
    /// callers choose `settle` (transitions) or `settleToFixedPoint`
    /// (matrix cells) before reading geometry.
    func makeRoot(for state: UIState) -> RootSplitViewController {
        // Reset the persisted mode BEFORE the controller exists, so every
        // state starts from the same place regardless of what ran before it.
        //
        // `RootSplitViewController` seeds `editingMode` from
        // `Preferences.editingMode` at init and `applyZenChrome`
        // short-circuits on `guard isZen != on`. Without this line the matrix
        // was order dependent: `*-zen-light` left the preference at `.zen`,
        // so the NEXT root came up already believing it was in zen,
        // `setEditingMode(.zen)` became a no-op, the Library never closed,
        // and `*-zen-dark` ran with the Library still open — a "zen" cell
        // that was not in zen. Appearance must never change geometry; before
        // this it did.
        Preferences.editingMode = .normal

        let root = RootSplitViewController()
        // Construction is placement, not motion (docs/motion.md: at rest,
        // nothing animates). Zen's chrome now FADES on the animated lane
        // (C3), so a zen cell built on `.system` would return mid-fade — the
        // band not yet hidden, the fresh-layout cache poisoned. Drive the
        // whole configuration through the instant branches and restore the
        // caller's policy before returning; suites that test the animated
        // lane keep `.system` for the transitions THEY drive.
        let incomingPolicy = root.motionPolicyForTesting
        root.motionPolicyForTesting = .instant
        defer { root.motionPolicyForTesting = incomingPolicy }
        window.rootViewController = root
        root.loadViewIfNeeded()
        root.view.appearance = NSAppearance(named: state.appearance == .dark ? .darkAqua : .aqua)
        root.setLibraryLocationsForTesting([libraryFolder])
        root.setSidebarVisible(state.sidebar == .shown)
        window.setContentSize(Self.size(for: state))
        window.layoutIfNeeded()
        root.view.layoutIfNeeded()
        // Full screen is a chrome MODE, not a window size: the band keeps
        // its windowed height at the screen's top edge. Nothing else in a
        // test can flip it.
        root.setMacFullscreenForTesting(state.window == .fullscreen)
        window.layoutIfNeeded()
        root.view.layoutIfNeeded()
        // The outline axis, before zen: zen closes the panel the way it
        // closes the Library, so a zen cell requested with the panel open
        // must reach zen with the panel already open and watch it close.
        root.setTrailingPanelForTesting(state.outline)
        window.layoutIfNeeded()
        root.view.layoutIfNeeded()
        // `setEditingMode` runs AFTER the window has its real size and a real
        // layout pass, never before: `applyZenChrome` only transitions
        // `displayMode` to `.secondaryOnly` once the split view has resolved
        // its size class against real geometry. Calling it pre-layout (as
        // this used to) left `displayMode` un-transitioned —
        // `chromeLayout(for:)` then reported the SAME `libraryPanel` rect for
        // zen as for normal, making zen look geometrically inert.
        // This ordering also matches the real app, which never toggles zen
        // before its window has a real frame.
        root.setEditingMode(state.mode == .zen ? .zen : .normal)
        window.layoutIfNeeded()
        root.view.layoutIfNeeded()
        return root
    }

    /// The transition-step settle: two layout passes and two runloop turns,
    /// the minimum that lets the split view's own async passes land (the
    /// stateless fallback; with a `state` it runs to a fixed point instead).
    /// Settle after a step. With a `state` it runs to the layout's FIXED
    /// POINT; without one it falls back to two runloop turns.
    ///
    /// Two turns was enough on an idle machine and not on a loaded one: a
    /// sidebar hide lands its display-mode change in a completion, so under
    /// load the audit read a half-applied step and reported it as "the step
    /// did not take" (seen while a screenshot run and two builds shared the
    /// machine, 2026-08-24). A fixed point is what the invariant matrix
    /// already waits for, and it costs nothing when the step is instant.
    func settle(_ root: RootSplitViewController, state: UIState? = nil,
                budget: TimeInterval = 0.1, stableTurns: Int = 1,
                reaching: ((RootSplitViewController) -> Bool)? = nil) {
        guard let state else {
            window.layoutIfNeeded()
            root.view.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            window.layoutIfNeeded()
            root.view.layoutIfNeeded()
            return
        }
        _ = settleToFixedPoint(root, state: state, budget: budget,
                               stableTurns: stableTurns, reaching: reaching)
    }

    /// Settle until the reported layout has stopped moving, or give up when
    /// `budget` expires. Returns whether a fixed point was reached; the caller
    /// decides how loudly to fail.
    ///
    /// Fixed point, not a fixed turn count: two turns were measured NOT to be
    /// reliably enough for the split view's re-tile after a hide (2026-08-23:
    /// one zen cell still showed the divider-gutter residue while its sibling
    /// had settled).
    ///
    /// `reaching` makes the fixed point one of the EXPECTED state, not merely
    /// of the current one. A `UISplitViewController` hide lands its
    /// `displayMode` change in a completion, and the layout it reports is
    /// momentarily unchanged between the request and that completion — a bare
    /// stability test therefore stops one turn too early and the caller audits
    /// a half-applied step (`displayMode says sidebar shown, expected
    /// nosidebar`). With a predicate the loop keeps turning until the
    /// configuration the caller asked for is really in force AND the layout
    /// has stopped moving, or the budget runs out.
    ///
    /// `stableTurns` is how many CONSECUTIVE unchanged turns count as still.
    /// One is enough for the resting-state suites; a full-screen chip
    /// raise lands a turn after the layout first looks settled, so the
    /// transition suite (whose fresh-layout oracle is cached and therefore
    /// permanent once wrong) asks for more.
    ///
    /// A wall-clock budget rather than a turn count: `RunLoop.run(until:)`
    /// returns as soon as it has handled input, so N turns is not N x 10ms of
    /// real time and a loaded machine got far less settling than an idle one.
    @discardableResult
    func settleToFixedPoint(_ root: RootSplitViewController, state: UIState,
                            budget: TimeInterval = 0.1, stableTurns: Int = 1,
                            reaching: ((RootSplitViewController) -> Bool)? = nil) -> Bool {
        let deadline = Date(timeIntervalSinceNow: budget)
        var previous = root.chromeLayout(for: state)
        var stable = 0
        repeat {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            window.layoutIfNeeded()
            root.view.layoutIfNeeded()
            let current = root.chromeLayout(for: state)
            stable = current == previous ? stable + 1 : 0
            previous = current
            if stable >= stableTurns && (reaching?(root) ?? true) { return true }
        } while Date() < deadline
        return false
    }
}
