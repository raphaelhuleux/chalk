import UIKit
import ChalkKit
import os

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    /// Scene-lifecycle breadcrumbs: every connect / foreground / activate
    /// prints what the window holds, so an empty window says whether it is a
    /// ghost scene or a live window whose surfaces failed to come back
    /// (docs/issues/2026-08-18-window-comes-up-empty-after-switching.md). Read
    /// with:
    ///   log stream --device --predicate 'subsystem == "com.huleux.chalk"'
    private static let stateLog = Logger(subsystem: "com.huleux.chalk", category: "scene")

    /// This scene's root, nil before connect builds it.
    private var root: RootSplitViewController? {
        window?.rootViewController as? RootSplitViewController
    }

    private func logState(_ event: String, _ scene: UIScene) {
        let line = event
            + " session=" + scene.session.persistentIdentifier
            + " role=" + scene.session.role.rawValue
            + " activation=" + String(describing: scene.activationState)
            + " scenes=" + String(UIApplication.shared.connectedScenes.count)
            + " " + (root?.stateSummary ?? "root=nil")
        Self.stateLog.info("\(line, privacy: .public)")
    }

    /// The AppKit plugin (ChalkAppKitGlue.bundle), loaded once: real AppKit for
    /// window chrome UIKit doesn't expose. nil if the bundle is missing
    /// (copy-phase regression, re-signing/notarization failure);
    /// RootSplitViewController then falls back to the UIKit header strip so
    /// every window still has tab UI.
    private static let appKitGlue: NSObject.Type? = {
        let candidates = [
            Bundle.main.builtInPlugInsURL, Bundle.main.privateFrameworksURL,
            Bundle.main.resourceURL,
        ]
        for dir in candidates {
            let url = (dir ?? Bundle.main.bundleURL)
                .appendingPathComponent("ChalkAppKitGlue.bundle")
            guard let bundle = Bundle(url: url), bundle.load() else { continue }
            return bundle.classNamed("ChalkAppKitGlue") as? NSObject.Type
        }
        return nil
    }()

    /// Whether the AppKit glue bundle loaded (and exposes its entry point).
    /// RootSplitViewController keys its Mac chrome on this: glue present →
    /// AppKit titlebar strip; glue missing → the UIKit header band is the tab
    /// UI.
    static let isAppKitGlueAvailable: Bool =
        appKitGlue?.responds(to: NSSelectorFromString("applyChromeStyling")) ?? false

    /// Restyle every titled NSWindow (transparent titlebar + editor-surface
    /// window background). Called on each scene connect, so windows created
    /// later are covered by the connect that created them.
    static func applyAppKitChromeStyling() {
        let log = Logger(subsystem: "com.huleux.chalk", category: "glue")
        guard let glue = appKitGlue else {
            log.error("ChalkAppKitGlue.bundle failed to load — falling back to the UIKit tab strip")
            return
        }
        // responds(to:) first: a bare perform on selector skew between app and
        // bundle raises NSInvalidArgumentException at launch.
        let selector = NSSelectorFromString("applyChromeStyling")
        guard glue.responds(to: selector) else {
            log.error("ChalkAppKitGlue loaded but does not implement applyChromeStyling — selector skew; falling back to the UIKit tab strip")
            return
        }
        _ = glue.perform(selector)
    }

    /// The recovery store is app-level. Every connecting scene layers records
    /// matching its own restored tabs; this flag makes the LEFTOVER drain
    /// (records no restoring window claimed) run once per process — otherwise
    /// each new window would "recover" snapshots of tabs that are dirty RIGHT
    /// NOW in other windows as duplicates.
    private static var didDrainRecovery = false

    /// The audit harness assumes a Welcome-only cold start; restored tabs from
    /// a previous run would break it.
    private static var isRestorationDisabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["CHALK_DISABLE_RESTORATION"] != nil || env["CHALK_AUDIT_STATE"] != nil
    }

    /// Ghost-scene defenses: the OS reconnects every scene session it ever
    /// persisted, so a launch can spawn windows nobody asked for. Per connect,
    /// only the first activity-less scene gets Welcome (ghosts open empty: no
    /// document, no webview); then one settle sweep destroys surplus empty
    /// windows once the restore burst is over. Decision logic:
    /// `SceneLaunchPolicy` (ChalkKit, unit-tested).
    private static var applicationSceneConnectOrdinal = 0
    private static var didScheduleSettleSweep = false

    private static func sweepSurplusEmptyScenes() {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        let counts = scenes.map { scene in
            scene.windows
                .compactMap { ($0.rootViewController as? RootSplitViewController)?.openTabCount }
                .first ?? 0
        }
        let victims = SceneLaunchPolicy.launchSweepVictims(openTabCounts: counts)
        guard !victims.isEmpty else { return }
        stateLog.info("settle sweep: destroying \(victims.count) of \(scenes.count) scenes (empty ghosts)")
        for index in victims {
            UIApplication.shared.requestSceneSessionDestruction(
                scenes[index].session, options: nil)
        }
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        Self.applicationSceneConnectOrdinal += 1
        let isFirstScene = Self.applicationSceneConnectOrdinal == 1

        let window = UIWindow(windowScene: windowScene)
        let locations = LocationStore(
            bookmarks: WindowLocations.store(
                forWindow: session.persistentIdentifier,
                isRestoredWindow: session.stateRestorationActivity != nil))
        let root = RootSplitViewController(
            locationStore: locations,
            initialContent: initialContent(
                for: session, options: connectionOptions,
                isFirstApplicationScene: isFirstScene))
        window.rootViewController = root
        self.window = window
        window.makeKeyAndVisible()

        // A New Window request from the sidebar carries the file to show. The
        // window is already built empty by `initialContent`, so this is the one
        // call that fills it — openExternalDocument also takes the security
        // scope and reveals the editor column.
        let newWindowInfo = connectionOptions.userActivities.first {
            $0.activityType == ChalkActivity.newWindowType
        }?.userInfo
        if let url = newWindowInfo?[ChalkActivity.urlKey] as? URL {
            root.openExternalDocument(url)
        }
        // A folder from outside that no window showed (ExternalOpenRouter).
        if let bookmark = newWindowInfo?[ChalkActivity.folderBookmarkKey] as? Data,
           let folder = FileBookmark.resolve(bookmark) {
            root.addFolderToWindow(folder)
        }

        // Mac window chrome: the tab strip is a real AppKit NSToolbar item
        // owned by ChalkAppKitGlue (ChalkTabStrip.swift). Catalyst never
        // delivers touches to toolbar custom views
        // (`UIBarButtonItem(customView:)`), so interactive titlebar content
        // must be AppKit. Tab state syncs over NotificationCenter
        // (`TabStripBridge`).
        windowScene.titlebar?.titleVisibility = .hidden
        // First-ever window floor: below this the header chrome and editor
        // column stop being coherent (justification: ChalkMetrics.minWindowSize).
        windowScene.sizeRestrictions?.minimumSize = ChalkMetrics.minWindowSize
        // Bind-token fallback lane: publish the invisible title now, before the
        // deferred glue styling attaches the toolbar, so a glue whose KVC probe
        // yields nothing can pair this window by reading NSWindow.title on its
        // first attempt. Retired (title restored) the moment the scene binds.
        root.publishBindToken(on: windowScene)
        // The unified toolbar's band is a system material that ignores
        // everything UIKit renders (UIWindow.backgroundColor included). Only
        // NSWindow.titlebarAppearsTransparent clears it, so the glue applies it
        // with the editor surface as the window background. Async: the scene's
        // NSWindow joins NSApp.windows after this callback returns.
        DispatchQueue.main.async { Self.applyAppKitChromeStyling() }

        // Crash recovery, per scene: every connecting scene first claims the
        // records matching its own restored tabs (reopened clean; the snapshot
        // text layers on as unsaved edits). Records carry no window identity,
        // so this match keeps one window from recovering another window's dirty
        // file as a duplicate.
        //
        // The cold-start switch (`isRestorationDisabled`: the audit harness)
        // skips the journal too. It promises a Welcome-only window, and the
        // harness kills the app between states, so each state's dirty buffers
        // would otherwise come back as tabs in the next. Both lanes share the
        // switch, or the cold start is only cold the first time.
        if !Self.isRestorationDisabled {
            root.restoreRecoveredBuffers(matchingOwnTabsOnly: true)
            // The leftover drain (drafts, files no restoring window claimed) runs
            // once per process, deferred one runloop turn so every restoring scene
            // has connected and claimed its own records first.
            if !Self.didDrainRecovery {
                Self.didDrainRecovery = true
                DispatchQueue.main.async {
                    root.restoreRecoveredBuffers(matchingOwnTabsOnly: false)
                }
            }
        } else if !Self.didDrainRecovery {
            // A cold start is cold on both lanes: the previous (killed) run's
            // residue is dropped rather than recovered, once per process and
            // before this launch writes its own first snapshot, so the journal
            // cannot pile up across a UI-test run either.
            Self.didDrainRecovery = true
            RecoveryStore(directory: RecoveryStore.appDirectory).clearAll()
        }

        // Cold launch from Finder: the file(s) the user opened
        // arrive here, not through scene(_:openURLContexts:). Runs after any
        // restored tabs, so the Finder file lands as one more tab on top.
        ExternalOpenRouter.route(connectionOptions.urlContexts.map(\.url), receivedBy: root)

        logState("connect ordinal=" + String(Self.applicationSceneConnectOrdinal)
                 + " restored=" + String(session.stateRestorationActivity != nil), scene)

        // Settle sweep, once per process: 0.5s gives every restoring scene
        // (and the recovery drain above, which runs on the next turn) time to
        // land its tabs, then surplus empty windows are destroyed.
        if !Self.didScheduleSettleSweep {
            Self.didScheduleSettleSweep = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Self.sweepSurplusEmptyScenes()
            }
        }
    }

    /// What this window opens with. The priorities live in
    /// `SceneLaunchPolicy.initialContent` (ChalkKit, unit-tested); this maps
    /// the session/options onto its inputs. Key behavior: an activity-less
    /// scene beyond the first is a ghost and opens EMPTY, never a duplicate
    /// Welcome, and a cold Finder open gets an empty window for its file
    /// rather than Welcome-plus-file.
    private func initialContent(
        for session: UISceneSession,
        options: UIScene.ConnectionOptions,
        isFirstApplicationScene: Bool
    ) -> SceneConnectContent {
        var restored: WindowSession?
        if let activity = session.stateRestorationActivity,
           activity.activityType == ChalkActivity.windowType,
           let data = activity.userInfo?[ChalkActivity.stateKey] as? Data {
            restored = WindowSession(data: data)
        }
        let isNewWindowRequest = options.userActivities.contains {
            $0.activityType == ChalkActivity.newWindowType
        }
        return SceneLaunchPolicy.initialContent(
            restoredSession: restored,
            isNewWindowRequest: isNewWindowRequest,
            hasURLContexts: !options.urlContexts.isEmpty,
            isFirstApplicationScene: isFirstApplicationScene,
            isRestorationDisabled: Self.isRestorationDisabled)
    }

    /// The snapshot the OS stores with the scene session and hands back through
    /// `session.stateRestorationActivity` at the next connect.
    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        guard !Self.isRestorationDisabled else { return nil }
        return root?.captureRestorationActivity()
    }

    /// On Mac the red close button destroys one scene while the app keeps
    /// running, and Catalyst offers no "save changes?" prompt there. Closing
    /// the window is the user's own "done with this", so it saves; left
    /// unsaved, its edits would drain into another window at the next launch.
    /// Elsewhere a disconnect is the system discarding a background scene,
    /// which the snapshot journal covers without touching the user's files.
    func sceneDidDisconnect(_ scene: UIScene) {
        logState("disconnect", scene)
        let root = self.root
        root?.snapshotDirtyBuffers()
        // Scopes release only after the async writes land: revoking a sandbox
        // extension mid-write would fail the save. A destroyed scene must not
        // keep costing file descriptors.
        saveAllDocuments { root?.releaseExternalScopes() }
    }

    /// Warm open: a file double-clicked (or dropped on the Dock icon) while the
    /// app is already running. Without this the OS hands us the URL and we drop
    /// it, so "nothing happens" on the second and later opens.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let root else { return }
        ExternalOpenRouter.route(URLContexts.map(\.url), receivedBy: root)
    }

    // Chalk does not autosave: backgrounding and resigning active (every
    // Cmd-Tab on Mac) only write the synchronous crash-recovery snapshot, so
    // an edit survives a kill or a crash without the file on disk changing
    // before the user saves.
    func sceneDidEnterBackground(_ scene: UIScene) {
        root?.snapshotDirtyBuffers()
        // An orderly departure from the foreground. Anything that leaves the
        // marker armed past this point was a death nobody handled.
        AlphaSession.shared.markClean()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        root?.snapshotDirtyBuffers()
    }

    /// The saves are async `UIDocument` writes; without a background-task
    /// assertion the process can suspend before the write callbacks land.
    /// `completion` runs once the writes have landed (or immediately when
    /// there is nothing to save).
    private func saveAllDocuments(then completion: (() -> Void)? = nil) {
        guard let root else {
            completion?()
            return
        }
        var task = UIBackgroundTaskIdentifier.invalid
        let end = {
            if task != .invalid {
                UIApplication.shared.endBackgroundTask(task)
                task = .invalid
            }
        }
        task = UIApplication.shared.beginBackgroundTask(withName: "chalk.saveAll", expirationHandler: end)
        root.saveAllDocuments {
            end()
            completion?()
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        logState("willEnterForeground", scene)
        // Arm the crash marker. Both this and didBecomeActive call it, because
        // either can be the one that runs and arming twice is harmless.
        AlphaSession.shared.markForeground()
        // Reflect edits made to open files (or the folder tree) while we were away.
        root?.reloadExternalChanges()
    }

    /// The moment the user is actually looking at this window.
    func sceneDidBecomeActive(_ scene: UIScene) {
        logState("didBecomeActive", scene)
        AlphaSession.shared.markForeground()
        // On Mac a visible window never re-enters the foreground when the app is reactivated, so
        // willEnterForeground alone misses edits made in another app. FileWatcher is the live path.
        root?.reloadExternalChanges()
        // After the window is settled, not during connect: a banner appearing
        // mid-restore lands over a half-built editor and reads as a failure.
        // claimCrashPrompt makes the extra activations harmless.
        root?.presentAlphaNoticeIfNeeded()
    }
}
