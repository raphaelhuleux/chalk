import AppKit
import ChalkKit
import os

/// The AppKit shell's application delegate. Owns the editor windows for their
/// lifetime (AppKit does not retain window controllers), the main menu, the
/// window journal that brings every window back at the next launch, and the
/// routing of files handed to the app from outside.
/// Attached in main.swift, not through `@main`: with `@main` on this class the
/// delegate was never attached and the app sat in its run loop with no window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Every live editor window, oldest first. A controller leaves when its
    /// window closes.
    private(set) var editorWindows: [EditorWindowController] = []

    /// Launch and window breadcrumbs, notice level so `log show` keeps them
    /// without `--info`. Read with:
    ///   log show --last 5m --predicate 'subsystem == "com.huleux.chalk"'
    private static let log = Logger(subsystem: "com.huleux.chalk", category: "app")

    /// Per-window state lines (what each window holds), on the category the
    /// Catalyst scene delegate used so the log queries stay the same.
    private static let stateLog = Logger(subsystem: "com.huleux.chalk", category: "scene")

    /// The app's one Settings window, made on first use and kept.
    private var settingsWindow: SettingsWindowController?

    /// Where the journal and the per-window Locations live: the app's own
    /// defaults, or a throwaway suite under test.
    private let defaults: UserDefaults
    private let journal: WindowSessionJournal

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        journal = WindowSessionJournal(defaults: defaults)
        super.init()
    }

    /// URLs the OS handed over before launch finished (a cold Finder open):
    /// routed once the restored windows exist, so the file lands as one more
    /// tab rather than in a window that is about to be replaced.
    private var pendingExternalURLs: [URL] = []
    private var didFinishLaunching = false

    /// Set the moment a quit starts: windows closing under termination must
    /// not be struck from the journal, or nothing would come back.
    private var isTerminating = false

    /// The recovery store is app-level. Every restored window layers the
    /// records matching its own tabs; the LEFTOVER drain (records no window
    /// claimed) runs once per process, or each new window would "recover"
    /// snapshots of tabs that are dirty right now in other windows.
    private static var didDrainRecovery = false

    /// The audit harness assumes a Welcome-only cold start; restored tabs from
    /// a previous run would break it.
    static var isRestorationDisabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["CHALK_DISABLE_RESTORATION"] != nil || env["CHALK_AUDIT_STATE"] != nil
    }

    // MARK: - Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        recordLaunch()
        NSApp.mainMenu = MainMenu.build()
    }

    /// Runs before any window: constructing `AlphaSession` reads and clears
    /// the launch marker, which every later read depends on.
    private func recordLaunch() {
        let alpha = AlphaSession.shared
        let verdict: Int
        switch alpha.verdict {
        case .firstLaunch: verdict = 0
        case .clean: verdict = 1
        case .abnormal: verdict = 2
        }
        Diagnostics.record(.launch, a: verdict)
        // Corroboration only: a crash with no dirty buffers leaves no residue,
        // so it cannot stand in for the marker.
        let residue = RecoveryStore(directory: RecoveryStore.appDirectory).pendingCount()
        if residue > 0 { Diagnostics.record(.recoveryResidueFound, a: residue) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        restoreWindows()
        if editorWindows.isEmpty {
            // The priorities live in `SceneLaunchPolicy` (ChalkKit, unit-tested):
            // the first window gets Welcome, a cold Finder open gets an empty
            // window for its file rather than Welcome-plus-file.
            let content = SceneLaunchPolicy.initialContent(
                restoredSession: nil,
                isNewWindowRequest: false,
                hasURLContexts: !pendingExternalURLs.isEmpty,
                isFirstApplicationScene: true,
                isRestorationDisabled: Self.isRestorationDisabled)
            openNewWindow(initialContent: content)
        }
        didFinishLaunching = true
        if !pendingExternalURLs.isEmpty {
            routeExternalOpen(pendingExternalURLs)
            pendingExternalURLs = []
        }
        // The leftover drain, once per process, deferred one runloop turn so
        // every restored window has claimed its own records first.
        if !Self.didDrainRecovery {
            Self.didDrainRecovery = true
            DispatchQueue.main.async { [weak self] in
                self?.frontmostEditorWindow?.root.restoreRecoveredBuffers(matchingOwnTabsOnly: false)
            }
        }
        Self.log.notice("launched; windows=\(self.editorWindows.count, privacy: .public)")
        // The crash prompt, once the window is on screen and settled: a banner
        // appearing mid-restore lands over a half-built editor.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.frontmostEditorWindow?.root.presentAlphaNoticeIfNeeded()
        }
        #if DEBUG
        applyDebugLaunchEnvironment()
        #endif
    }

    /// Bring back every window of the last session, from the journal. A cold
    /// start (`isRestorationDisabled`) skips the journal and drops the
    /// previous run's recovery residue instead of recovering it, once per
    /// process and before this launch writes its first snapshot, so the
    /// journal cannot pile up across a UI-test run.
    func restoreWindows() {
        guard !Self.isRestorationDisabled else {
            if !Self.didDrainRecovery {
                Self.didDrainRecovery = true
                RecoveryStore(directory: RecoveryStore.appDirectory).clearAll()
            }
            return
        }
        let records = journal.load()
        // Lists of windows no record can bring back (a death before the first
        // journal write) would otherwise pile up in the defaults forever.
        WindowLocations.discardAll(except: records.map(\.id), defaults: defaults)
        for record in records {
            var frame: NSRect?
            if let stored = record.frame {
                frame = NSRect(x: stored.x, y: stored.y, width: stored.width, height: stored.height)
            }
            openNewWindow(windowID: record.id, initialContent: .restoreSession(record.session),
                          frame: frame, isRestored: true)
        }
        // Crash recovery, per window: the records matching its own restored
        // tabs (reopened clean; the snapshot text layers on as unsaved edits).
        // Records carry no window identity, so this match keeps one window
        // from recovering another window's dirty file as a duplicate.
        for controller in editorWindows {
            controller.root.restoreRecoveredBuffers(matchingOwnTabsOnly: true)
        }
        if !records.isEmpty {
            Self.stateLog.info("restored \(records.count, privacy: .public) window(s) from the journal")
        }
    }

    // MARK: - Activity and quit

    func applicationDidBecomeActive(_ notification: Notification) {
        AlphaSession.shared.markForeground()
    }

    /// Every Cmd-Tab away: flush the dirty documents, write the crash net and
    /// the journal. Chalk does not autosave; this is the one automatic flush.
    func applicationDidResignActive(_ notification: Notification) {
        for controller in editorWindows {
            controller.root.saveAllDocuments()
            controller.root.snapshotDirtyBuffers()
        }
        writeJournal()
    }

    /// An orderly quit: the journal first, then every window's documents
    /// (async writes), and only then the exit. A save that never calls back
    /// must not hold the quit forever.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        writeJournal()
        let roots = editorWindows.map(\.root)
        guard !roots.isEmpty else { return .terminateNow }
        var remaining = roots.count
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        for root in roots {
            root.snapshotDirtyBuffers()
            root.saveAllDocuments {
                remaining -= 1
                if remaining == 0 { reply() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: reply)
        return .terminateLater
    }

    /// Anything that leaves the marker armed past this was a death nobody handled.
    func applicationWillTerminate(_ notification: Notification) {
        AlphaSession.shared.markClean()
    }

    /// The app outlives its last window, like every Mac document app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Windows

    @discardableResult
    func openNewWindow(windowID: String = UUID().uuidString,
                       initialContent: SceneConnectContent = .openWelcome,
                       frame: NSRect? = nil,
                       isRestored: Bool = false) -> EditorWindowController {
        let locations = LocationStore(
            bookmarks: WindowLocations.store(forWindow: windowID, isRestoredWindow: isRestored, defaults: defaults))
        let controller = EditorWindowController(
            windowID: windowID, initialContent: initialContent, locationStore: locations, frame: frame)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windowDidClose(controller)
        }
        controller.onBecomeKey = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.logState("key", controller)
        }
        editorWindows.append(controller)
        controller.showWindow(nil)
        logState(isRestored ? "restored" : "opened", controller)
        return controller
    }

    /// The window closed for good (not under a quit): its Locations go with
    /// it, and the journal no longer lists it.
    private func windowDidClose(_ controller: EditorWindowController) {
        logState("closed", controller)
        editorWindows.removeAll { $0 === controller }
        guard !isTerminating else { return }
        WindowLocations.discard(windows: [controller.windowID], defaults: defaults)
        writeJournal()
    }

    /// Journal order is front to back, so the frontmost window restores last
    /// and ends up on top.
    private func writeJournal() {
        guard !Self.isRestorationDisabled else { return }
        journal.save(orderedEditorWindows().reversed().map { $0.windowRecord() })
    }

    /// Editor windows, frontmost first: the key one, then screen order, then
    /// any that is not on screen in opening order.
    private func orderedEditorWindows() -> [EditorWindowController] {
        var ordered: [EditorWindowController] = []
        for window in NSApp.orderedWindows {
            if let controller = editorWindows.first(where: { $0.window === window }) {
                ordered.append(controller)
            }
        }
        for controller in editorWindows where !ordered.contains(where: { $0 === controller }) {
            ordered.append(controller)
        }
        if let key = ordered.first(where: { $0.window?.isKeyWindow == true }) {
            ordered.removeAll { $0 === key }
            ordered.insert(key, at: 0)
        }
        return ordered
    }

    var frontmostEditorWindow: EditorWindowController? { orderedEditorWindows().first }

    /// One line per window event: what the window holds, never what it is
    /// named (`stateSummary` is counts, flags and a closed vocabulary).
    private func logState(_ event: String, _ controller: EditorWindowController) {
        let line = event
            + " window=" + String(controller.window?.windowNumber ?? -1)
            + " windows=" + String(editorWindows.count)
            + " " + controller.root.stateSummary
        Self.stateLog.info("\(line, privacy: .public)")
    }

    @objc func cmdNewWindow(_ sender: Any?) { openNewWindow(initialContent: .openEmpty) }

    // MARK: - Files from outside

    /// Finder double-click, "Open With", `open -a Chalk`, a drop on the Dock
    /// icon: warm or cold. Before launch finishes the URLs wait for the
    /// restored windows.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard didFinishLaunching else {
            pendingExternalURLs += urls
            return
        }
        routeExternalOpen(urls)
    }

    private func routeExternalOpen(_ urls: [URL]) {
        let ordered = orderedEditorWindows()
        let candidates = ordered.map { controller in
            ExternalOpenRouter.Candidate(root: controller.root) { [weak controller] in
                controller?.window?.makeKeyAndOrderFront(nil)
            }
        }
        let receiver = ordered.first ?? openNewWindow(initialContent: .openEmpty)
        ExternalOpenRouter.route(urls, receivedBy: receiver.root, candidates: candidates) {
            openNewWindow(initialContent: .openEmpty).root
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Settings

    /// Focus the Settings window, making it only the first time: ⌘, must
    /// never stack Settings windows.
    func showSettings() {
        let controller = settingsWindow ?? SettingsWindowController()
        settingsWindow = controller
        #if DEBUG
        controller.container.openCommandTime = CACurrentMediaTime()
        #endif
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// On the delegate too: with no editor window, the app menu's item still
    /// resolves through the responder chain's end.
    @objc func cmdSettings(_ sender: Any?) { showSettings() }

    #if DEBUG
    var settingsWindowForTesting: SettingsWindowController? { settingsWindow }

    /// Debug launch switches for screenshots and manual checks:
    /// `CHALK_AUDIT_STATE` (the audit harness, `AuditMode`), `CHALK_DEBUG_LIBRARY=<folder>`,
    /// `CHALK_DEBUG_PALETTE=quick-open|outline|outline-panel|settings|settings-shortcuts` and
    /// `CHALK_DEBUG_SCRIPT=<seconds>:<action>,...` (actions: new-tab, close-tab,
    /// toggle-sidebar, toggle-outline-panel, quick-open), which drives the shell on a clock so
    /// a screen recording can catch a flicker no screenshot shows.
    private func applyDebugLaunchEnvironment() {
        guard let controller = frontmostEditorWindow else { return }
        controller.root.applyAuditStateIfRequested()
        let env = ProcessInfo.processInfo.environment
        if let script = env["CHALK_DEBUG_SCRIPT"], !script.isEmpty {
            for step in script.split(separator: ",") {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let delay = Double(parts[0]) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak controller] in
                    guard let root = controller?.root else { return }
                    switch parts[1] {
                    case "new-tab": root.cmdNewFile(nil)
                    case "close-tab": root.cmdCloseTab(nil)
                    case "toggle-sidebar": root.cmdToggleSidebar(nil)
                    case "toggle-outline-panel": root.cmdToggleOutlinePanel(nil)
                    case "quick-open": root.cmdQuickOpen(nil)
                    default: break
                    }
                }
            }
        }
        if let path = env["CHALK_DEBUG_LIBRARY"], !path.isEmpty {
            controller.root.setLibraryLocationsForTesting([URL(fileURLWithPath: path)])
            controller.root.setSidebarVisible(true)
        }
        if let palette = env["CHALK_DEBUG_PALETTE"], !palette.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                switch palette {
                case "quick-open": controller.root.cmdQuickOpen(nil)
                case "outline": controller.root.cmdToggleOutline(nil)
                case "outline-panel": controller.root.cmdToggleOutlinePanel(nil)
                case "settings": self.showSettings()
                case "settings-shortcuts":
                    self.showSettings()
                    self.settingsWindow?.container.selectRailForTesting(section: 1, row: 1)
                default: break
                }
            }
        }
    }
    #endif
}
