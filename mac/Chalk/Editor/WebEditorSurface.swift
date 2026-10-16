import AppKit
import WebKit
import ChalkKit
import os

/// The editor's WKWebView.
///
/// No key-equivalent lane of its own: AppKit evaluates the menu bar's key equivalents, and a
/// Cmd-key the page consumes (`preventDefault`, see `SHELL_COMMANDS` in web/src/native-host.ts)
/// comes back over the transport-internal `command` message too. One press can arrive over both
/// lanes, which `RootSplitViewController.admitShellAction` collapses. Copy and cut are WebKit's own on AppKit.
final class EditorWebView: WKWebView {}

/// The surface's view: holds the web view under the pre-paint cover. The container installs
/// and removes the host; the cover is the host's own business.
final class EditorSurfaceHostView: NSView {
    /// Opaque, in the editor's tone, above the web view. An alpha of 0 on the web view was
    /// not enough: its content is a remote layer whose first frame reached the screen white
    /// regardless, for one frame, when the page process produced its first composite.
    private let cover = PrePaintCoverView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        cover.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cover)
        NSLayoutConstraint.activate([
            cover.leadingAnchor.constraint(equalTo: leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: trailingAnchor),
            cover.topAnchor.constraint(equalTo: topAnchor),
            cover.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The web view goes under the cover.
    func install(_ webView: NSView) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView, positioned: .below, relativeTo: cover)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    var isCovering: Bool { !cover.isHidden }
    func coverWebView() { cover.isHidden = false }
    func liftCover() { cover.isHidden = true }
}

/// The pre-paint cover: the editor's tone under the current appearance and theme.
final class PrePaintCoverView: ThemedView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        chalkSetLayerBackground(.chalkEditorBackground)
    }

    override func refreshColors() { needsDisplay = true }
}

/// `WKUserContentController` retains its handler strongly, so registering the surface directly
/// would form a retain cycle that only `teardown()` breaks. This weak shim lets a surface dropped
/// without teardown deallocate and take its web content process with it.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// `EditorSurface` backed by a `WKWebView` running `@chalk/editor-core`.
/// Editor to host: `window.webkit.messageHandlers.chalkHost.postMessage`; host to editor:
/// `evaluateJavaScript("window.__chalkHost.receive(<json>)")`.
///
/// Text pushes (`init`/`update`) before `ready` are queued and flushed on it. Settings (editor
/// config, heading colours, snippets) are latest-value state: never queued, sent on `ready` ahead
/// of the seed.
final class WebEditorSurface: NSObject, EditorSurface {
    weak var delegate: EditorSurfaceDelegate?
    /// The host, not the web view itself: the pre-paint cover lives beside the
    /// web view inside it.
    var view: NSView { host }
    private let host = EditorSurfaceHostView()

    /// Fires when recovery is exhausted (the watchdog reload also timed out, or the bundle is
    /// missing) so the shell shows an error instead of a blank tab. A closure, not a delegate
    /// method, because the delegate is DocumentController and this is a shell concern.
    var onFailedToBecomeReady: (() -> Void)?

    /// Exposed for the shell's `takeSnapshot` covers and the tests; the seam is `view`.
    let webView: EditorWebView
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let log = Logger(subsystem: "com.huleux.chalk", category: "surface")

    private var isReady = false
    /// Text pushes waiting for `ready`. Only `init`/`update`: queued settings would pile up one
    /// per Settings slider tick on a dormant tab.
    private var pending: [HostToEditorMessage] = []
    /// One-shot pre-ready watchdog, armed by every `loadBundle()`. A JS throw before `ready`
    /// produces no navigation error or process termination, so without it the tab stays blank.
    /// First expiry reloads once; the second gives up visibly.
    private var readyWatchdog: DispatchWorkItem?
    private var didAttemptWatchdogReload = false
    /// Set from the watchdog reload's `loadBundle()` until that navigation commits, while `ready`
    /// is ignored. The old page's JS runs until commit; honoring its late `ready` would flush the
    /// queued init into a dying page and leave the reloaded one blank with no watchdog armed.
    private var awaitingWatchdogReloadCommit = false
    private static let readyTimeout: TimeInterval = 5
    private var desiredDark = true // default matches the bundle's :root (dark)
    private var desiredTheme = ChalkTheme.ink // likewise: :root is Ink
    private var desiredScale = 1.0
    /// CSS custom properties on the page's root element, by name, as CSS values. Latest-value
    /// state: a change goes out at once when ready, and every `ready` re-sends them all in one
    /// script. The font size is seeded because the page always gets it, even at the default scale.
    private var cssVariables: [String: String] = [
        WebEditorSurface.fontSizeVariable: WebEditorSurface.fontSize(scale: 1.0),
    ]
    /// Re-sent on `ready`: a web-process crash clears `pending`, and the fresh editor would
    /// otherwise fall back to defaults.
    private var desiredEditorConfig: JSONValue?
    /// Re-sent on `ready`. Empty means the toggle is off; nil means the shell never spoke.
    private var desiredHeadingColors: HeadingColors?
    /// Re-sent on `ready`. The page keeps snippets across re-inits, so one send per page
    /// generation is enough.
    private var desiredHsnips: String?
    private static let baseFontSize = 17.0 // must match chalk-theme.css :root
    private static let fontSizeVariable = "--vscode-editor-font-size"
    private static func fontSize(scale: Double) -> String { "\(baseFontSize * scale)px" }

    override init() {
        let config = WKWebViewConfiguration()
        config.userContentController = WKUserContentController()
        webView = EditorWebView(frame: .zero, configuration: config)
        super.init()

        config.userContentController.add(WeakScriptMessageHandler(self), name: "chalkHost")
        // User scripts are installed per load (installUserScripts): one carries the theme, which
        // the shell sets between construction and boot.
        webView.navigationDelegate = self
        // Boot is deferred to bootIfNeeded(): booting every restored background tab at launch
        // exhausted file descriptors. Pre-boot messages queue in `pending` like pre-ready ones.
        // The page's own `:root` background is the editor colour from the first paint (the theme
        // seed is a document-start script), and the under-page colour covers overscroll. Before
        // that first paint AppKit's WKWebView composites WHITE, and it has no public opaque
        // switch (a private `drawsBackground` toggle is not an option), so the host keeps an
        // opaque cover over the web view until the page has painted twice after `ready`.
        webView.underPageBackgroundColor = .chalkEditorBackground
        webView.allowsLinkPreview = false
        host.install(webView)
    }

    /// Bumped per cover, so a lift scheduled for one page generation cannot uncover the next.
    private var coverGeneration = 0

    /// Lift the cover once the page has composited the editor's tone: two animation frames
    /// after `ready`, asked of the page itself (a fixed delay races the async repaint). The
    /// backstop lifts it regardless, so a page whose frames never come is never a blank tab.
    private func revealWebView(afterPaint: Bool) {
        guard host.isCovering else { return }
        coverGeneration += 1
        let generation = coverGeneration
        let lift = { [weak self] in
            guard let self, self.coverGeneration == generation else { return }
            self.host.liftCover()
        }
        guard afterPaint else { return lift() }
        afterNextPaint(lift)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: lift)
    }

    func afterNextPaint(_ completion: @escaping () -> Void) {
        webView.callAsyncJavaScript(
            "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))",
            in: nil, in: .page
        ) { _ in completion() }
    }

    /// Called on the tab's first show. Until then the WKWebView holds no page, no web content
    /// process and no watchdog.
    private var hasBooted = false
    func bootIfNeeded() {
        guard !hasBooted else { return }
        hasBooted = true
        Self.log.info("boot: loading editor bundle")
        loadBundle()
    }

    /// Document-start scripts, rebuilt on every load because the theme is set after construction.
    /// The theme seed is the only lane ahead of first paint: the stylesheet defaults to dark Ink and
    /// `applyAppearance` waits for `ready`, so any other look would flash Ink dark on every new
    /// surface.
    private func installUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        // Scroll telemetry feeds chrome auto-hide. The page posts per scrolled frame
        // only when the host opts in with this flag.
        controller.addUserScript(WKUserScript(
            source: "window.__chalkWantsScrollTelemetry = true",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(
            source: appearanceScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
    }

    private func loadBundle() {
        installUserScripts()
        guard let dir = Bundle.main.url(forResource: "editor", withExtension: nil) else {
            assertionFailure("editor bundle missing from app Resources")
            // Release builds skip the assertion: surface it like a watchdog failure.
            Self.log.error("editor bundle missing from app Resources")
            notifyFailedToBecomeReady()
            return
        }
        let html = dir.appendingPathComponent("editor.html")
        webView.loadFileURL(html, allowingReadAccessTo: dir)
        armReadyWatchdog()
    }

    /// See `readyWatchdog`. Unlike crash recovery, the reload keeps `pending` and does not ask
    /// the controller to re-seed: nothing was delivered yet, so the queued init must survive.
    private func armReadyWatchdog() {
        readyWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isReady else { return }
            if !self.didAttemptWatchdogReload {
                self.didAttemptWatchdogReload = true
                self.awaitingWatchdogReloadCommit = true
                Self.log.error("editor not ready after \(Self.readyTimeout, privacy: .public)s — reloading bundle once")
                self.loadBundle()
            } else {
                Self.log.error("editor not ready after reload — giving up; surfacing error")
                self.notifyFailedToBecomeReady()
            }
        }
        readyWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyTimeout, execute: work)
    }

    // Async, so a missing-bundle failure fired inside `bootIfNeeded()` reaches the shell after
    // its caller returns.
    private func notifyFailedToBecomeReady() {
        // Not hidden behind the cover: the shell's error state must show.
        revealWebView(afterPaint: false)
        DispatchQueue.main.async { [weak self] in self?.onFailedToBecomeReady?() }
    }

    // MARK: EditorSurface (host → editor)

    /// Text-push generation, bumped on every `init`/`update`. The editor echoes it on each `edit`;
    /// a stale echo was produced against a replaced buffer and is dropped (see `deliverEdit`).
    private(set) var textPushEpoch = 0

    func initialize(text: String, language: EditorLanguage, editorConfig: JSONValue?) {
        textPushEpoch += 1
        send(.initialize(text: text, language: language, editorConfig: editorConfig,
                         epoch: textPushEpoch))
    }
    func update(text: String) {
        textPushEpoch += 1
        send(.update(text: text, epoch: textPushEpoch))
    }
    // The setters skip an unchanged value: Settings pushes every setting to every tab on each
    // slider tick. `ready` re-sends through send/apply, not the setters, so a reload gets all.
    func setHeadingColors(_ colors: HeadingColors) {
        guard colors != desiredHeadingColors else { return }
        desiredHeadingColors = colors
        guard isReady else { return } // sent on `ready`
        send(.headingColors(colors))
    }
    func setEditorConfig(_ config: JSONValue) {
        guard config != desiredEditorConfig else { return }
        desiredEditorConfig = config
        guard isReady else { return } // sent on `ready`
        send(.editorConfig(config))
    }
    func setHsnips(content: String) {
        guard content != desiredHsnips else { return }
        desiredHsnips = content
        guard isReady else { return } // sent on `ready`
        send(.hsnips(content: content))
    }

    // Sent on every `ready`, before the delegate seeds, so mountEditor builds the first view with
    // these settings instead of defaults.
    private func sendEditorSettings() {
        if let config = desiredEditorConfig { send(.editorConfig(config)) }
        if let colors = desiredHeadingColors { send(.headingColors(colors)) }
        if let hsnips = desiredHsnips { send(.hsnips(content: hsnips)) }
    }

    func setAppearance(dark: Bool, theme: ChalkTheme) {
        desiredDark = dark
        desiredTheme = theme
        #if DEBUG
        appearancePushCountForTesting += 1
        #endif
        // The colour WebKit shows wherever the page has not painted yet: a
        // strip exposed when the view grows (a tab reinstalled after the
        // column widened behind it) wore the construction-time default for
        // the frames before the repaint, a block in the wrong tone.
        webView.underPageBackgroundColor = .chalkEditorBackground(dark: dark, theme: theme)
        applyAppearance()
    }

    #if DEBUG
    /// Whether the pre-paint cover has lifted.
    var isWebViewRevealedForTesting: Bool { !host.isCovering }
    /// Run a script in the page (the debug script's `scroll:` action).
    func evaluateForDebug(_ js: String) { webView.evaluateJavaScript(js, completionHandler: nil) }
    var userScriptsForTesting: [WKUserScript] {
        webView.configuration.userContentController.userScripts
    }
    var desiredDarkForTesting: Bool { desiredDark }
    /// Counts `setAppearance` calls, including ones that push the theme already shown.
    private(set) var appearancePushCountForTesting = 0
    /// Host-to-editor messages in delivery order; queued ones appear when flushed.
    private(set) var deliveredMessagesForTesting: [HostToEditorMessage] = []
    private(set) var evaluatedScriptsForTesting: [String] = []
    var headingColorsForTesting: HeadingColors? { desiredHeadingColors }
    var editorConfigForTesting: JSONValue? { desiredEditorConfig }
    var fontScaleForTesting: Double { desiredScale }
    #endif

    private func applyAppearance() {
        guard isReady else { return } // re-applied on `ready`
        webView.evaluateJavaScript(appearanceScript, completionHandler: nil)
    }

    /// Sets the page's light/dark (`data-theme`) and colour theme (`data-palette`), which select
    /// chalk-theme.css's blocks. Both values are enum-derived, so safe to interpolate.
    private var appearanceScript: String {
        "document.documentElement.setAttribute('data-theme', '\(desiredDark ? "dark" : "light")');"
            + "document.documentElement.setAttribute('data-palette', '\(desiredTheme.rawValue)')"
    }

    func setFontScale(_ scale: Double) {
        desiredScale = scale
        setCSSVariable(Self.fontSizeVariable, Self.fontSize(scale: scale))
    }

    /// Editor scroll offsets (transport-internal `scroll` messages); drive the chrome auto-hide.
    var onScroll: ((Double) -> Void)?

    /// The persistent outline panel's feed (see `setOutlineSubscription`).
    var onOutline: ((OutlineSnapshot) -> Void)?
    /// Re-applied on `ready`, so a panel open across a crash reload keeps receiving pushes.
    private var desiredOutlineSubscription = false

    func setOutlineSubscription(_ on: Bool) {
        desiredOutlineSubscription = on
        applyOutlineSubscription()
    }

    private func applyOutlineSubscription() {
        guard isReady else { return }
        webView.evaluateJavaScript(
            "window.__chalkEditor?.setOutlineSubscription(\(desiredOutlineSubscription))",
            completionHandler: nil)
    }

    #if DEBUG
    var isOutlineSubscribedForTesting: Bool { desiredOutlineSubscription }
    #endif

    /// The overlay band's height as a CSS variable: the text rests this far down but scrolls
    /// under the band. Not deduplicated: unlike the Settings sliders, the container sends it only
    /// on a change or a tab activation.
    func setChromeTopInset(_ points: Double) {
        setCSSVariable(Self.chromeTopVariable, "\(Int(points.rounded()))px", skipUnchanged: false)
    }
    private static let chromeTopVariable = "--chalk-chrome-top"

    /// Changes the resting offset with a FLIP glide (docs/motion.md "Zen / normal"). The end
    /// state matches the plain setter's; `ready` re-applies it through the instant path.
    // A scrolled document absorbs the delta in `scrollTop`; only the residual glides, as a
    // transform on `#root` easing to zero. Never transition the padding itself: CM6 reflows every
    // frame and the caret lags. A newer glide folds the in-flight transform in; stale cleanups
    // are epoch-discarded.
    func setChromeTopInset(_ points: Double, animatedOverSeconds duration: TimeInterval) {
        guard isReady, duration > 0 else {
            setChromeTopInset(points)
            return
        }
        let px = Int(points.rounded())
        // The script below writes the variable itself; keep the stored value in step for `ready`.
        cssVariables[Self.chromeTopVariable] = "\(px)px"
        let ms = Int((duration * 1000).rounded())
        let js = """
        (function () {
          // CHROME-TOP-GLIDE-JS-BEGIN
          var doc = document.documentElement;
          var prev = parseFloat(doc.style.getPropertyValue('--chalk-chrome-top'));
          if (!isFinite(prev)) { prev = 0; }
          var next = \(px);
          var ms = \(ms);
          doc.style.setProperty('--chalk-chrome-top', next + 'px');
          var delta = next - prev;
          var host = document.getElementById('root');
          var scroller = document.querySelector('.cm-scroller');
          if (!host || !delta) { return; }
          var shift = delta;
          if (scroller && scroller.scrollTop > 0) {
            void scroller.scrollHeight; // flush the padding change before clamping
            var target = Math.max(0, scroller.scrollTop + delta);
            var applied = target - scroller.scrollTop;
            scroller.scrollTop = target;
            shift = delta - applied;
          }
          if (!shift) { return; }
          window.__chalkGlideEpoch = (window.__chalkGlideEpoch || 0) + 1;
          var epoch = window.__chalkGlideEpoch;
          var carried = 0;
          var current = getComputedStyle(host).transform;
          if (current && current !== 'none') {
            var m = current.match(/matrix\\(([^)]+)\\)/);
            if (m) { carried = parseFloat(m[1].split(',')[5]) || 0; }
          }
          host.style.transition = 'none';
          host.style.transform = 'translateY(' + (carried - shift) + 'px)';
          void host.offsetHeight; // commit the frozen frame
          requestAnimationFrame(function () {
            if (window.__chalkGlideEpoch !== epoch) { return; }
            host.style.transition = 'transform ' + ms + 'ms ease-in-out';
            host.style.transform = 'translateY(0px)';
            setTimeout(function () {
              if (window.__chalkGlideEpoch !== epoch) { return; }
              host.style.transition = '';
              host.style.transform = '';
            }, ms + 80);
          });
          // CHROME-TOP-GLIDE-JS-END
        })();
        """
        evaluate(js)
    }

    /// Width of the centered text column (Settings slider).
    func setMeasure(_ px: Double) {
        setCSSVariable("--chalk-measure", "\(Int(px.rounded()))px")
    }

    /// Interline spacing as a unitless multiplier. Written to --chalk-line-height-pref because
    /// chalk-theme.css declares --chalk-line-height on `.editor-host`, shadowing the root.
    func setLineHeight(_ multiplier: Double) {
        setCSSVariable("--chalk-line-height-pref", String(format: "%.2f", multiplier))
    }

    /// Wrapped-prose alignment. An enum, so its `cssValue` is safe to interpolate into the script.
    func setTextAlign(_ alignment: EditorTextAlignment) {
        setCSSVariable("--chalk-text-align", alignment.cssValue)
    }

    /// Store `value` and, once ready, write it to the page. `skipUnchanged` drops a repeat of the
    /// stored value (see setHeadingColors). Names and values are ours, safe to interpolate.
    private func setCSSVariable(_ name: String, _ value: String, skipUnchanged: Bool = true) {
        if skipUnchanged, cssVariables[name] == value { return }
        cssVariables[name] = value
        guard isReady else { return } // sent on `ready`
        evaluate(Self.setPropertyScript(name, value))
    }

    /// Every stored variable in one script, so a fresh page takes them all in one turn.
    private func applyCSSVariables() {
        guard isReady, !cssVariables.isEmpty else { return }
        evaluate(cssVariables.sorted { $0.key < $1.key }
            .map { Self.setPropertyScript($0.key, $0.value) }
            .joined(separator: ";"))
    }

    private static func setPropertyScript(_ name: String, _ value: String) -> String {
        "document.documentElement.style.setProperty('\(name)', '\(value)')"
    }

    /// A `focusEditor()` that arrived before `ready`, replayed once the page has an editor.
    private var wantsFocusOnReady = false

    func focusEditor() {
        webView.window?.makeFirstResponder(webView)
        guard isReady else {
            wantsFocusOnReady = true
            return
        }
        // Restore the DOM focus `blurEditor()` dropped: first responder alone leaves
        // activeElement on <body> and keystrokes die. After the native grab so WebKit doesn't
        // re-assert behind a still-open overlay.
        webView.evaluateJavaScript(
            "window.__chalkEditor?.focus()", completionHandler: nil)
    }

    func blurEditor() {
        wantsFocusOnReady = false
        // Drop the DOM focus so WebKit has nothing to restore first responder for; the native
        // resign is the overlay's `makeFirstResponder`.
        webView.evaluateJavaScript(
            "document.activeElement && document.activeElement.blur()",
            completionHandler: nil)
    }

    /// Outline and cursor line over the `window.__chalkEditor` bridge. The `??` fallback covers
    /// the pre-`init` window where the bridge exists but no view does.
    func fetchOutline(completion: @escaping (OutlineSnapshot?) -> Void) {
        let js = "JSON.stringify(window.__chalkEditor?.getOutlineSnapshot()"
            + " ?? {items:[],cursorLine:1})"
        webView.evaluateJavaScript(js) { [decoder] result, _ in
            guard let json = result as? String,
                  let snapshot = try? decoder.decode(OutlineSnapshot.self, from: Data(json.utf8))
            else {
                completion(nil)
                return
            }
            completion(snapshot)
        }
    }

    func captureSnapshot(_ completion: @escaping (NSImage?) -> Void) {
        guard isReady, !host.isCovering, webView.window != nil else { return completion(nil) }
        webView.takeSnapshot(with: nil) { image, _ in completion(image) }
    }

    /// Jump to a 1-based line.
    func revealLine(_ line: Int) {
        webView.evaluateJavaScript(
            "window.__chalkEditor?.gotoLine(\(line))", completionHandler: nil)
    }

    func teardown() {
        readyWatchdog?.cancel()
        readyWatchdog = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "chalkHost")
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
    }

    // MARK: Outbound encoding

    private func send(_ msg: HostToEditorMessage) {
        guard isReady else {
            pending.append(msg)
            return
        }
        guard let json = jsonLiteral(msg) else { return }
        #if DEBUG
        deliveredMessagesForTesting.append(msg)
        #endif
        evaluate("window.__chalkHost.receive(\(json))") { _, error in
            if let error {
                Self.log.error("host→editor eval failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// `value` as a JS literal for `evaluateJavaScript`, or nil when it does not encode.
    private func jsonLiteral<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else { return nil }
        // JSON allows raw U+2028/U+2029 in strings but pre-ES2019 JS literals don't. Our WebKit
        // floor accepts them; escape anyway, since failure would be a silently dropped `init`.
        guard json.contains("\u{2028}") || json.contains("\u{2029}") else { return json }
        return json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private func evaluate(_ js: String, completion: ((Any?, Error?) -> Void)? = nil) {
        #if DEBUG
        evaluatedScriptsForTesting.append(js)
        #endif
        webView.evaluateJavaScript(js, completionHandler: completion)
    }

    private func flushPending() {
        let queued = pending
        pending.removeAll()
        for msg in queued { send(msg) }
    }
}

// MARK: - Navigation (process-crash recovery)

extension WebEditorSurface: WKNavigationDelegate {
    /// After commit, every script message comes from the new page, so stale `ready`s are over.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        awaitingWatchdogReloadCommit = false
    }

    /// WebKit killed our content process: reload, and the controller re-seeds on the next `ready`.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        // The reload paints white first, like a boot: cover it until the next `ready`.
        coverGeneration += 1
        host.coverWebView()
        // Stale queued messages would flush into the fresh editor; the controller re-seeds via
        // `editorDidResetConnection`.
        pending.removeAll()
        delegate?.editorDidResetConnection(self)
        loadBundle()
    }
}

// MARK: - Inbound (editor → host)

extension WebEditorSurface: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        handleHostMessage(body: message.body)
    }

    /// The receive path after the WKScriptMessage unwrap, so tests can drive it with a plain
    /// dictionary (WKScriptMessage cannot be fabricated).
    func handleHostMessage(body: Any) {
        guard let body = body as? [String: Any],
              let type = body["type"] as? String else { return }

        // Transport-internal messages first: none of these are HostPort messages.
        if type == "resolve-asset" {
            handleResolveAsset(body)
            return
        }

        // Workspace access for path/citation completion.
        if type == "list-files" {
            handleListFiles(body)
            return
        }
        if type == "read-text" {
            handleReadText(body)
            return
        }

        // The page never scrolls natively (CM6 scrolls .cm-scroller), so this is the shell's only
        // view of editor scrolling.
        if type == "scroll" {
            if let y = body["y"] as? Double { onScroll?(y) }
            return
        }

        // Outline push for the persistent panel, decoded through the same OutlineSnapshot as the
        // pull path so panel and palette share one wire shape.
        if type == "outline" {
            guard JSONSerialization.isValidJSONObject(body),
                  let data = try? JSONSerialization.data(withJSONObject: body),
                  let snapshot = try? decoder.decode(OutlineSnapshot.self, from: data)
            else {
                Self.log.error("dropped a malformed outline push")
                return
            }
            onOutline?(snapshot)
            return
        }

        // A shell shortcut the focused webview consumed (e.g. Cmd+S).
        if type == "command", let name = body["name"] as? String {
            delegate?.editor(self, requestsCommand: name)
            return
        }

        // Fast path: 'edit' carries the whole document per keystroke, and the generic decode
        // would serialize and re-parse it. A malformed 'edit' falls through to the logged drop.
        if type == "edit", let text = body["text"] as? String {
            deliverEdit(text: text, epoch: body["epoch"] as? Int)
            return
        }

        // isValidJSONObject first: JSONSerialization.data raises an uncatchable ObjC exception on
        // non-JSON leaf types. Log drops, since a silent one hides protocol skew.
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              let msg = try? decoder.decode(EditorToHostMessage.self, from: data) else {
            Self.log.error("dropped undecodable editor→host message: \(String(describing: body), privacy: .private)")
            return
        }
        switch msg {
        case .ready:
            guard !awaitingWatchdogReloadCommit else {
                // From the page the watchdog reload is replacing: see `awaitingWatchdogReloadCommit`.
                Self.log.info("ignoring ready from the pre-reload page generation")
                return
            }
            isReady = true
            revealWebView(afterPaint: true)
            Self.log.info("ready received; flushing \(self.pending.count) pending message(s)")
            // Reset the one-reload budget for a later crash reload.
            readyWatchdog?.cancel()
            readyWatchdog = nil
            didAttemptWatchdogReload = false
            // Before the seed, so the `init` builds the view with these settings.
            sendEditorSettings()
            delegate?.editorDidBecomeReady(self)
            flushPending()
            applyAppearance()
            applyCSSVariables()
            if desiredOutlineSubscription { applyOutlineSubscription() }
            // Only while shown: a tab switched away from mid-boot must not
            // pull first responder from the one now on screen.
            if wantsFocusOnReady {
                wantsFocusOnReady = false
                if webView.window != nil { focusEditor() }
            }
        case let .edit(text, epoch):
            deliverEdit(text: text, epoch: epoch)
        case let .openExternal(urlString):
            if let url = URL(string: urlString) {
                delegate?.editor(self, requestsOpenExternal: url)
            }
        }
    }

    // Drop an edit that predates the current text push: a keystroke in flight during a reopen
    // would otherwise record the old document's text as the new file's edit and overwrite it on
    // save. A nil epoch (a bundle without the echo) is accepted.
    private func deliverEdit(text: String, epoch: Int?) {
        if let epoch, epoch != textPushEpoch {
            Self.log.info("dropped stale edit echo (epoch \(epoch) != \(self.textPushEpoch))")
            return
        }
        delegate?.editor(self, didEdit: text)
    }

    private func handleListFiles(_ body: [String: Any]) {
        guard let id = body["id"] as? Int else { return }
        let kinds = (body["kinds"] as? [String] ?? []).compactMap(WorkspaceFileKind.init(rawValue:))
        reply("listFilesReply", id: id) { await $0.editor(self, listFiles: kinds) }
    }

    private func handleReadText(_ body: [String: Any]) {
        guard let id = body["id"] as? Int, let path = body["path"] as? String else { return }
        reply("readTextReply", id: id) { await $0.editor(self, readText: path) }
    }

    private func handleResolveAsset(_ body: [String: Any]) {
        guard let id = body["id"] as? Int, let src = body["src"] as? String else { return }
        reply("resolveAssetReply", id: id) { await $0.editor(self, resolveAsset: src) }
    }

    // Answers a transport-internal request by passing the JSON answer (or `null`) to
    // `window.__chalkHost.<function>`. The delegate is read on the main actor, where it is set.
    private func reply<Answer: Encodable>(
        _ function: String, id: Int,
        ask: @escaping (EditorSurfaceDelegate) async -> Answer?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var answer: Answer?
            if let delegate = self.delegate { answer = await ask(delegate) }
            let literal = answer.flatMap { self.jsonLiteral($0) } ?? "null"
            self.evaluate("window.__chalkHost.\(function)(\(id), \(literal))")
        }
    }
}
