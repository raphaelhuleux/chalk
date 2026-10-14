import AppKit
import os

/// AppKit plugin loaded at runtime by the Catalyst app (see
/// SceneDelegate.loadAppKitGlue), for window chrome UIKit for Mac doesn't
/// expose. Talks to the UIKit side only through `TabStripBridge` notifications.
@objc(ChalkAppKitGlue)
public final class ChalkAppKitGlue: NSObject {
    /// Info-level pairing breadcrumbs (`/usr/bin/log stream --info`).
    private static let log = Logger(subsystem: "com.huleux.chalk", category: "glue")
    private static var observer: NSObjectProtocol?

    /// Makes every titled window's titlebar transparent over the editor color
    /// and attaches the tab-strip toolbar. Idempotent; the host calls it on
    /// each scene connect.
    @objc public static func applyChromeStyling() {
        styleAllWindows()
        // The scene's UINSWindow registers with NSApp AFTER the scene-connect
        // call, so the call above usually sees no windows. Re-run on window
        // updates (an unattended launch never becomes active, so didBecomeKey
        // alone can leave a window without its toolbar) and on key changes.
        // Idempotent, so over-firing is harmless.
        guard observer == nil else { return }
        // isAttachCandidate keeps the steady state one map lookup per tick.
        updateObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow, isAttachCandidate(window)
            else { return }
            styleAllWindows()
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            styleAllWindows()
            // Re-assert the bind for the new key window. Idempotent on the
            // UIKit side; `isKeyFact` is what shell-command routing (Cmd+S/W)
            // runs on, instead of UIKit key inference.
            if let window = note.object as? NSWindow,
               let controller = toolbarControllers.object(forKey: window) {
                // Re-assert the titlebar band's place on top of the titlebar:
                // a full-screen round trip rebuilds that hierarchy under us.
                controller.installBand(in: window)
                postBind(for: window, isKeyFact: true)
            }
        }
        // AppKit colours here resolve against the window's NSAppearance, which
        // follows the SYSTEM appearance, not the app's forced Light/Dark. The
        // app posts its appearance and the window adopts it; "system" hands it
        // back to the OS. The theme rides along in the same post.
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: TabStripBridge.windowAppearance,
            object: nil, queue: .main
        ) { note in
            if let theme = (note.userInfo?[TabStripBridge.themeKey] as? String)
                .flatMap(ChalkTheme.init(rawValue:)) {
                applyTheme(theme)
            }
            let style = (note.userInfo?[TabStripBridge.styleKey] as? String)
                .flatMap(TabStripBridge.Appearance.init(rawValue:))
            let appearance: NSAppearance? = switch style {
            case .dark: NSAppearance(named: .darkAqua)
            case .light: NSAppearance(named: .aqua)
            case .system, nil: nil
            }
            for window in NSApplication.shared.windows
            where window.styleMask.contains(.titled)
                && !WindowRouting.isNoChromeTitle(window.title) {
                guard window.appearance !== appearance else { continue }
                window.appearance = appearance
            }
        }
        // The UIKit side has no handle to the toolbar we install, so it posts
        // show/hide tagged with its bound window. See `target(of:)`.
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: TabStripBridge.setVisible,
            object: nil, queue: .main
        ) { note in
            guard let visible = note.userInfo?[TabStripBridge.visibleKey] as? Bool,
                  let (window, controller) = target(of: note) else { return }
            controller.setChromeVisible(visible, in: window)
        }
        // Auto-hide fades rather than hides: hiding the toolbar collapses the
        // titlebar and resizes the content area. The fade also covers the
        // painted background, which lives in the titlebar, not the toolbar.
        fadeObserver = NotificationCenter.default.addObserver(
            forName: TabStripBridge.setFaded,
            object: nil, queue: .main
        ) { note in
            guard let faded = note.userInfo?[TabStripBridge.fadedKey] as? Bool,
                  let (_, controller) = target(of: note) else { return }
            // A composed transition sends its duration (0 = instant); an
            // untagged post is auto-hide (docs/motion.md, Tokens).
            let duration = note.userInfo?[TabStripBridge.durationKey] as? TimeInterval
                ?? ChromeMotion.autoHide
            controller.setChipsFaded(faded, duration: duration)
        }
        // UIKit cannot show a resize pointer, so the shell reports when the
        // pointer is over a resize grip and this side pushes the cursor.
        resizeCursorObserver = NotificationCenter.default.addObserver(
            forName: TabStripBridge.shellResizeCursor,
            object: nil, queue: .main
        ) { note in
            guard let inside = note.userInfo?[TabStripBridge.insideKey] as? Bool else { return }
            if inside, !resizeCursorPushed {
                NSCursor.resizeLeftRight.push()
                resizeCursorPushed = true
            } else if !inside, resizeCursorPushed {
                NSCursor.pop()
                resizeCursorPushed = false
            }
        }
        // A palette's dim is a UIKit view, and the titlebar is outside that
        // view tree, so the titlebar gets its own scrim.
        scrimObserver = NotificationCenter.default.addObserver(
            forName: TabStripBridge.setScrimmed,
            object: nil, queue: .main
        ) { note in
            guard let scrimmed = note.userInfo?[TabStripBridge.scrimmedKey] as? Bool,
                  let (_, controller) = target(of: note) else { return }
            let duration = note.userInfo?[TabStripBridge.durationKey] as? TimeInterval
                ?? ChromeScrim.fadeDuration
            controller.setScrimmed(scrimmed, duration: duration)
        }
        // Middle-click closes a tab. In full screen the strip is the UIKit
        // band, and Catalyst gives UIKit no middle button, so forward the
        // release point (top-left MAC points) and let the bound scene
        // hit-test it. Never consumed.
        middleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { event in
            guard event.buttonNumber == middleMouseButton,
                  let window = event.window ?? NSApp.keyWindow,
                  toolbarControllers.object(forKey: window) != nil
            else { return event }
            NotificationCenter.default.post(
                name: TabStripBridge.shellMiddleClick, object: nil,
                userInfo: [TabStripBridge.windowNumberKey: window.windowNumber,
                           TabStripBridge.xKey: event.locationInWindow.x,
                           TabStripBridge.yKey: window.frame.height - event.locationInWindow.y])
            return event
        }
        // ⌘P (outline). While a native text field edits, Catalyst hands the
        // keyDown to NSTextInputContext before any UIKit key command sees it,
        // and a ⌘-key read as cancel exits full screen
        // (docs/issues/2026-08-17-fullscreen-drops-when-outline-opens.md). A
        // local monitor runs before dispatch; match by character
        // (layout-independent), swallow, and post to the bound scene.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !event.isARepeat,
                  event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command,
                  event.charactersIgnoringModifiers == "p",
                  let window = event.window ?? NSApp.keyWindow,
                  toolbarControllers.object(forKey: window) != nil
            else { return event }
            log.info("keyMonitor: ⌘P claimed for window \(window.windowNumber, privacy: .public)")
            NotificationCenter.default.post(
                name: TabStripBridge.shellKey, object: nil,
                userInfo: [TabStripBridge.windowNumberKey: window.windowNumber,
                           TabStripBridge.nameKey: ShellCommand.toggleOutline.rawValue])
            return nil // consumed — must never reach the text-input funnel
        }
        #if DEBUG
        // Programmatic full-screen toggle for the audit harness (synthetic
        // keystrokes leak into other apps). Only DEBUG audit code posts this.
        debugToggleObserver = NotificationCenter.default.addObserver(
            forName: TabStripBridge.debugToggleFullScreen,
            object: nil, queue: .main
        ) { _ in
            let window = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
                .first { toolbarControllers.object(forKey: $0) != nil }
            window?.toggleFullScreen(nil)
        }
        #endif
    }

    /// The scene window a strip post names, and its toolbar controller.
    /// By number only: an unresolved number is a stale post and is dropped,
    /// since falling back to the key window would hand one scene's state to
    /// another scene's strip.
    private static func target(of note: Notification) -> (NSWindow, ChalkToolbarController)? {
        guard let number = note.userInfo?[TabStripBridge.windowNumberKey] as? Int,
              let window = NSApp.window(withWindowNumber: number),
              let controller = toolbarControllers.object(forKey: window)
        else { return nil }
        return (window, controller)
    }

    /// One toolbar controller per window, and its retain anchor (NSToolbar's
    /// delegate is unretained). Weak keys: a window torn down without
    /// willClose drops out on dealloc; willClose is just an eager prune.
    private static let toolbarControllers = NSMapTable<NSWindow, ChalkToolbarController>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)
    private static var closeObserver: NSObjectProtocol?
    private static var updateObserver: NSObjectProtocol?
    private static var visibilityObserver: NSObjectProtocol?
    private static var appearanceObserver: NSObjectProtocol?
    private static var fadeObserver: NSObjectProtocol?
    private static var scrimObserver: NSObjectProtocol?
    private static var resizeCursorObserver: NSObjectProtocol?
    /// Whether `NSCursor.resizeLeftRight` is on the cursor stack right now,
    /// so a stream of hover posts pushes once and pops once.
    private static var resizeCursorPushed = false
    #if DEBUG
    private static var debugToggleObserver: NSObjectProtocol?
    #endif
    private static var keyMonitor: Any?
    private static var middleClickMonitor: Any?
    /// AppKit numbers mouse buttons from 0 (left, right, middle).
    private static let middleMouseButton = 2

    /// Whether `styleAllWindows` would attach a toolbar now. Shared by the
    /// didUpdate gate and the attach site so they cannot drift.
    private static func isAttachCandidate(_ window: NSWindow) -> Bool {
        // Cheapest check first: this runs on every window update pass.
        guard toolbarControllers.object(forKey: window) == nil else { return false }
        return TitlebarAttachPolicy.shouldAttach(
            isTitled: window.styleMask.contains(.titled),
            isMiniaturizable: window.styleMask.contains(.miniaturizable),
            isSheet: window.isSheet,
            hasParent: window.parent != nil,
            hasNoChromeTitle: WindowRouting.isNoChromeTitle(window.title),
            alreadyAttached: false)
    }

    /// The strip's dynamic colours read `StripColor.theme`, which no
    /// NSAppearance change announces, so repaint every chrome window's views
    /// by hand. This bundle's own views also rerun their appearance hook,
    /// where they re-resolve the CGColors they cache in layers.
    private static func applyTheme(_ theme: ChalkTheme) {
        guard theme != StripColor.theme else { return }
        StripColor.theme = theme
        let glueBundle = Bundle(for: ChalkAppKitGlue.self)
        func repaint(_ view: NSView) {
            view.needsDisplay = true
            if Bundle(for: type(of: view)) == glueBundle {
                view.viewDidChangeEffectiveAppearance()
            }
            view.subviews.forEach(repaint)
        }
        for window in NSApplication.shared.windows
        where window.styleMask.contains(.titled)
            && !WindowRouting.isNoChromeTitle(window.title) {
            // The frame view holds the titlebar, where the strip lives.
            if let frame = window.contentView?.superview { repaint(frame) }
        }
    }

    private static func styleAllWindows() {
        let editorBackground = StripColor.paperFill
        for window in NSApplication.shared.windows where window.styleMask.contains(.titled) {
            // "No editor chrome" windows (Settings) keep a plain system
            // titlebar, which also keeps them draggable.
            if WindowRouting.isNoChromeTitle(window.title) { continue }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = editorBackground
            // Primary scene windows only: Catalyst gives form sheets their own
            // titled NSWindow. Predicate: TitlebarAttachPolicy (ChalkKit).
            if isAttachCandidate(window) {
                let controller = ChalkToolbarController()
                toolbarControllers.setObject(controller, forKey: window)
                controller.attach(to: window)
                log.info("attach: toolbar attached to window \(window.windowNumber, privacy: .public)")
                // A window restored straight INTO full screen never fires
                // didEnterFullScreen — apply the full-screen strip swap here.
                if window.styleMask.contains(.fullScreen) {
                    controller.setChromeVisible(false, in: window)
                    postFullScreenChange(for: window, on: true)
                }
                // Pair synchronously: a cold launch must not depend on a key
                // transition to show the scene's tabs.
                establishPairing(for: window)
            }
        }
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: nil, queue: .main
            ) { note in
                guard let window = note.object as? NSWindow else { return }
                toolbarControllers.removeObject(forKey: window)
            }
        }
        // In full screen macOS rehosts the toolbar into an
        // NSToolbarFullScreenWindow with an opaque background nothing public
        // can clear. Hide the toolbar there and let the UIKit side show its
        // own tab band. The UIKit side owns zen and re-asserts it after exit.
        if fullScreenObservers.isEmpty {
            let enter = NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main
            ) { note in
                guard let window = note.object as? NSWindow,
                      let controller = toolbarControllers.object(forKey: window) else { return }
                controller.setChromeVisible(false, in: window)
                postFullScreenChange(for: window, on: true)
            }
            let exit = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main
            ) { note in
                guard let window = note.object as? NSWindow,
                      let controller = toolbarControllers.object(forKey: window) else { return }
                controller.setChromeVisible(true, in: window)
                postFullScreenChange(for: window, on: false)
            }
            fullScreenObservers = [enter, exit]
        }
    }

    private static var fullScreenObservers: [NSObjectProtocol] = []

    /// Observed by RootSplitViewController.
    private static func postFullScreenChange(for window: NSWindow, on: Bool) {
        log.info("fullScreenChange: window \(window.windowNumber) on=\(on)")
        NotificationCenter.default.post(
            name: TabStripBridge.windowFullscreen, object: nil,
            userInfo: [TabStripBridge.windowNumberKey: window.windowNumber,
                       TabStripBridge.onKey: on])
    }

    // MARK: - Deterministic pairing
    //
    // The NSWindow↔UIWindow pairing is established here at toolbar attach and
    // posted as `bind`, never inferred from key status. Evidence: the KVC
    // bridge (the UIWindow object), else the scene's title token. The
    // matching decision lives in WindowRouting.bindTarget (ChalkKit).

    /// CHALK_DISABLE_KVC_PAIRING=1 forces the title-token path, proving the
    /// public-API lane works without KVC.
    private static var isKVCPairingDisabled: Bool {
        ProcessInfo.processInfo.environment["CHALK_DISABLE_KVC_PAIRING"] == "1"
    }

    /// KVC bridge, feature-detected: UINSWindow exposes a private `uiWindows`.
    /// value(forKey:) raises on unknown keys, so `responds(to:)` is probed
    /// first; any unexpected shape degrades to nil (title-token fallback).
    /// Passed on as an opaque object: this bundle never names UIKit types.
    private static func pairedUIWindowObject(for window: NSWindow) -> AnyObject? {
        guard !isKVCPairingDisabled else { return nil }
        guard window.responds(to: Selector(("uiWindows"))) else { return nil }
        guard let list = window.value(forKey: "uiWindows") as? [AnyObject] else { return nil }
        // Exactly one or nothing: a wrong object posts an identity no scene
        // verifies, which silently kills the binding.
        guard list.count == 1 else { return nil }
        return list.first
    }

    /// One `bind` post carrying all pairing evidence available now: both the
    /// UIWindow object and the title token, so a scene the KVC lane
    /// mis-identifies can still bind by token.
    private static func postBind(for window: NSWindow, isKeyFact: Bool) {
        var info: [String: Any] = [TabStripBridge.windowNumberKey: window.windowNumber]
        if isKeyFact { info[TabStripBridge.isKeyFactKey] = true }
        // A window restored into full screen posts `windowFullscreen` before
        // any scene has bound its number, so the state rides on every bind.
        info[TabStripBridge.isFullScreenKey] = window.styleMask.contains(.fullScreen)
        if let uiWindow = pairedUIWindowObject(for: window) {
            info[TabStripBridge.uiWindowKey] = uiWindow
        }
        if let token = WindowRouting.bindToken(fromTitle: window.title) {
            info[TabStripBridge.tokenKey] = token
        }
        log.info("postBind: window \(window.windowNumber) object=\(info[TabStripBridge.uiWindowKey] != nil) token=\(info[TabStripBridge.tokenKey] != nil) key=\(isKeyFact)")
        NotificationCenter.default.post(
            name: TabStripBridge.bind, object: nil, userInfo: info)
    }

    /// Post the bind now, then arm the title retry (the scene may not have
    /// published its token yet) and the 1s ack retry. The title retry arms
    /// unconditionally: a wrong-but-non-nil KVC object must not suppress it.
    private static func establishPairing(for window: NSWindow) {
        postBind(for: window, isKeyFact: window.isKeyWindow)
        scheduleTitleRetry(for: window, remaining: 3)
        scheduleAckRetry(for: window)
    }

    /// The pairing ACK: the strip has rendered its own state. A closed window
    /// counts as acked so retries die with it.
    private static func isAcked(_ window: NSWindow) -> Bool {
        guard let controller = toolbarControllers.object(forKey: window) else { return true }
        return controller.strip.hasEverAppliedOwnState
    }

    /// Until acked, re-read the pairing evidence up to `remaining` × 300ms and
    /// post once any is found.
    private static func scheduleTitleRetry(for window: NSWindow, remaining: Int) {
        guard remaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak window] in
            guard let window, !isAcked(window) else { return }
            if pairedUIWindowObject(for: window) != nil
                || WindowRouting.bindToken(fromTitle: window.title) != nil {
                postBind(for: window, isKeyFact: window.isKeyWindow)
            } else {
                scheduleTitleRetry(for: window, remaining: remaining - 1)
            }
        }
    }

    /// One 1s retry: if the strip is still unacked (the scene's observer may
    /// not be up at attach), re-post once. didBecomeKey covers the long tail.
    private static func scheduleAckRetry(for window: NSWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak window] in
            guard let window, !isAcked(window) else { return }
            postBind(for: window, isKeyFact: window.isKeyWindow)
        }
    }
}
