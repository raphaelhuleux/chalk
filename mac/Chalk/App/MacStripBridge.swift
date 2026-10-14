import UIKit
import ChalkKit
import os

/// What `MacStripBridge` needs from the scene root it serves.
///
/// The bridge owns the protocol (identity, posts, replay) and the root owns the
/// chrome (measurement, presentation, the editor). Main-thread only.
@MainActor
protocol MacStripBridgeHost: AnyObject {
    /// This scene's UIWindow, or nil while the view is unloaded/unhosted. Read
    /// without forcing a view load, or every passing bind post would build a
    /// view hierarchy.
    var stripBridgeWindow: UIWindow? { get }

    /// Whether this scene's window reports key to UIKit. The key gate is the
    /// fallback lane of `WindowRouting.sceneShouldHandle`, used only for a
    /// strip no scene has bound yet.
    var stripBridgeWindowIsKey: Bool { get }

    /// The scrim decision, recorded on the root (see
    /// `RootSplitViewController.postStripScrim`).
    var stripBridgeScrimmed: Bool { get }

    /// Re-measure the live divider and re-post the inset. The measurement is
    /// the root's; the post is the bridge's.
    func stripBridgePushLeadingInset()

    /// A binding was (re)established, or a strip asked for its state back.
    /// The window exists at this point, which is the earliest moment its
    /// NSAppearance can be set (the launch-time push from
    /// `applyThemePreference` runs before there is a window to receive it).
    func stripBridgeDidEstablishWindow()

    /// Full-screen state that rode in on a bind payload (see the glue's
    /// `postBind`): a window restored straight into full screen announced it
    /// before this scene was bound, so the routed post never landed.
    func stripBridgeApplyFullScreen(_ on: Bool)

    /// A click in the AppKit strip, already routed to this scene.
    func stripBridgePerform(_ action: MacStripBridge.StripAction)
}

/// The Catalyst titlebar-strip protocol: scene ↔ NSWindow identity, every state
/// post the scene addresses to its strip, and the three glue messages that come
/// back.
///
/// The tab strip is an AppKit view owned by ChalkAppKitGlue (Catalyst never
/// delivers touches to UIKit toolbar custom views). State flows out and clicks
/// flow back over the names and keys in ChalkKit's `TabStripBridge`, which the
/// glue compiles in.
///
/// Every post goes through the injected `poster` (default
/// `NotificationCenter.default`), so the state machine runs without a scene, a
/// window or the glue.
@MainActor
final class MacStripBridge {
    /// Where a post goes. Injected so a test can record instead of broadcast;
    /// the default is the real in-process lane the glue listens on.
    typealias Poster = (Notification.Name, [String: Any]) -> Void

    /// A click the AppKit strip sent back, parsed.
    enum StripAction: Equatable {
        case new
        case select(UUID)
        case close(UUID)
        case move(id: UUID, to: Int)
    }

    private weak var host: MacStripBridgeHost?
    private let poster: Poster

    // MARK: - Detach seam

    #if DEBUG
    /// Harness seam (ChromeMatrixHost), forwarded from
    /// `RootSplitViewController.stripBridgeDetachedForTesting` (see there for
    /// why). Recorded decisions (`last*`) still update, so the strip invariants
    /// keep their evidence.
    var isDetached = false
    #else
    /// Release builds compile the detach seam away.
    let isDetached = false
    #endif

    // MARK: - Recorded decisions

    // What the post sites last decided, recorded before the bound gate so an
    // unbound test root still records them (posting stays gated: an unbound
    // scene posts nothing). The strip's pixels live in ChalkAppKitGlue, which
    // no test links, so `chromeLayout(for:)` reports these into
    // `ChromeLayout.macStrip` and the strip invariants check them against
    // `MacStripExpectation.forState`.

    /// The divider inset `postLeadingInset` last computed (MAC points).
    private(set) var lastDividerX: CGFloat = 0
    /// The visibility `postVisibility` last carried. Seeded `true`: the glue
    /// shows the strip at attach and only a zen post hides it.
    private(set) var lastVisible = true
    /// The fade `postFaded` last carried. Seeded un-faded (rest state).
    private(set) var lastFaded = false

    /// Latest snapshot, re-pushed when the AppKit strip requests state (its
    /// window just became key).
    private var lastTabItems: [TabItem] = []
    /// Last divider X (MAC points) posted to the strip, to keep steady layout
    /// passes from spamming notifications. -1 forces the next push
    /// (`replayAll`).
    private var lastPostedDividerX: CGFloat = -1
    private var lastPostedOutlineWidth: CGFloat = 0

    // MARK: - Scene ↔ NSWindow identity binding
    //
    // The glue establishes the pairing at toolbar attach: it resolves this
    // window's UIWindow through the UINSWindow KVC bridge (or reads the title
    // token this scene publishes while unbound) and posts `chalk.tabstrip.bind`
    // with the evidence and the windowNumber. This scene binds on an exact
    // match (`WindowRouting.bindTarget`): no key flags, no scene census, no
    // delays. From then on every message carries the number and both sides
    // match on identity, so a ghost scene pairs with its own window or with
    // nothing.
    //
    // INVARIANT: a strip with an attached toolbar and a live paired scene
    // renders that scene's tabs within one runloop hop of attach. Cold
    // single-window launch must not depend on any key transition.

    /// The NSWindow number this scene's strip handshakes bound it to.
    /// Read through `boundNumber`, never directly: window numbers can be
    /// recycled and ghost scenes can mis-bind, so the registry below is the
    /// single source of truth for who currently owns a number.
    private var boundWindowNumber: Int?

    /// windowNumber → owning bridge, last binder wins. Rebinding releases the
    /// scene's previous number, or a mis-bound scene would stay authoritative
    /// for a window it no longer services.
    private static let sceneBindings = WindowBindingRegistry()

    /// The AppKit key window's number, from every glue `bind` post carrying
    /// `isKeyFact` (sent on each NSWindow key transition). Shell commands route
    /// on it (see `RootSplitViewController.target(forAction:withSender:)`).
    static var appKitKeyWindowNumber: Int?

    /// Title-token fallback lane: the token this scene publishes in its
    /// windowScene title while unbound, so a KVC-less glue can still pair it.
    /// Retired (title restored) the moment the scene binds.
    private var bindToken: String?
    /// Whatever title the scene carried before the token overwrote it
    /// (normally nil; titleVisibility is .hidden so neither is ever drawn).
    private var titleBeforeBindToken: String?
    /// The scene the token title was published on, so retiring can restore
    /// the title even if the view has left its window by then.
    private weak var bindTokenScene: UIWindowScene?

    /// Pairing breadcrumbs, info-level.
    private static let pairingLog = Logger(subsystem: "com.huleux.chalk", category: "pairing")

    // MARK: - Lifecycle

    init(host: MacStripBridgeHost?,
         poster: @escaping Poster = { name, info in
             NotificationCenter.default.post(name: name, object: nil, userInfo: info)
         }) {
        self.host = host
        self.poster = poster
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTabStripAction(_:)),
            name: TabStripBridge.action, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTabStripNeedsState(_:)),
            name: TabStripBridge.needsState, object: nil)
        // Pairing: the glue posts the NSWindow↔UIWindow fact and this scene
        // binds on an exact object/token match, with no UIKit key observation.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTabStripBind(_:)),
            name: TabStripBridge.bind, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Identity

    /// This scene's bound number, iff the registry still names it the owner.
    var boundNumber: Int? {
        guard let number = boundWindowNumber,
              Self.sceneBindings.isOwner(self, of: number)
        else { return nil }
        return number
    }

    /// Whether ANY live scene currently owns `number` — the
    /// `messageNumberHasOwner` input of `WindowRouting.sceneShouldHandle`.
    static func hasOwner(_ number: Int?) -> Bool {
        guard let number else { return false }
        return sceneBindings.hasOwner(number)
    }

    /// Should this scene act on a strip message? Routed by the strip's
    /// windowNumber to the scene BOUND to that window; the key gate survives
    /// only for a strip no scene has bound yet (and `sceneShouldHandle`
    /// refuses the key fallback when another scene owns the number, so an
    /// action can never be handled twice or by a stale-key ghost).
    func shouldHandle(_ note: Notification) -> Bool {
        let number = note.userInfo?[TabStripBridge.windowNumberKey] as? Int
        return WindowRouting.sceneShouldHandle(
            messageWindowNumber: number,
            boundWindowNumber: boundNumber,
            messageNumberHasOwner: Self.hasOwner(number),
            sceneWindowIsKey: host?.stripBridgeWindowIsKey ?? false)
    }

    /// Whether a glue message names the window this scene is bound to. By
    /// identity only: unlike `shouldHandle` there is no key-window fallback
    /// for an unbound scene, so an unbound or foreign-addressed scene ignores
    /// the message.
    func isAddressedToBoundWindow(_ note: Notification) -> Bool {
        guard let number = note.userInfo?[TabStripBridge.windowNumberKey] as? Int else { return false }
        return number == boundNumber
    }

    /// INVARIANT: after any binding change (first bind, migration to a new
    /// number, or stealing one from another scene) the new owner immediately
    /// pushes its full tab snapshot and inset, so a strip always renders the
    /// scene that owns its windowNumber.
    func bind(to number: Int) {
        boundWindowNumber = number
        retireBindTokenTitle()
        guard Self.sceneBindings.bind(self, to: number) else { return }
        replayAll()
    }

    /// Everything a strip needs to render this scene: the tabs, a forced
    /// inset re-post, the recorded decisions and the window's appearance. Run
    /// on a binding change and on a strip's request for state.
    private func replayAll() {
        pushTabs()
        // Forces the inset past the dedupe: the divider is never negative,
        // so -1 always differs from it.
        lastPostedDividerX = -1
        host?.stripBridgePushLeadingInset()
        replayStripState()
        // Earliest moment the window's NSAppearance can be set (see
        // `MacStripBridgeHost.stripBridgeDidEstablishWindow`).
        host?.stripBridgeDidEstablishWindow()
    }

    /// Replay every strip decision already taken onto the strip this scene just
    /// bound to (or that just asked for state).
    ///
    /// A post with no reader is lost, and a scene can decide before its window
    /// exists (launch restoring zen). Staying silent while unbound is safe only
    /// because binding replays it all.
    ///
    /// Visibility replays in the hide direction only: posting `true` would
    /// un-hide a toolbar full screen deliberately hid, and the glue already
    /// shows the strip at attach. The fade replays instantly (`over: 0`):
    /// restoration, not motion.
    private func replayStripState() {
        postFaded(lastFaded, over: 0)
        if !lastVisible { postVisibility(false) }
        sendScrim()
    }

    /// Publish the invisible bind-token title while this scene is unbound, so
    /// a glue whose KVC probe yielded nothing can still pair this window by
    /// reading `NSWindow.title` (the public-API fallback lane). Idempotent;
    /// called at scene connect (SceneDelegate, before the glue's deferred
    /// attach) and whenever bind traffic passes an unbound scene by.
    func publishBindToken(on scene: UIWindowScene) {
        guard boundNumber == nil else { return }
        if bindToken == nil { bindToken = UUID().uuidString }
        guard let token = bindToken else { return }
        let title = WindowRouting.bindTitle(token: token)
        if scene.title != title {
            titleBeforeBindToken = scene.title
            scene.title = title
        }
        bindTokenScene = scene
    }

    /// Bound: the token has done its job — restore the pre-token title (the
    /// title is invisible chrome-wise, but Mission Control / the Window menu
    /// can surface it) and stop matching on it.
    private func retireBindTokenTitle() {
        guard let token = bindToken else { return }
        if let scene = bindTokenScene ?? host?.stripBridgeWindow?.windowScene,
           scene.title == WindowRouting.bindTitle(token: token) {
            scene.title = titleBeforeBindToken ?? ""
        }
        bindToken = nil
        titleBeforeBindToken = nil
        bindTokenScene = nil
    }

    // MARK: - Posts out

    /// Serialize the current tabs to the AppKit strip.
    ///
    /// INVARIANT: every update is the full snapshot (active and preview
    /// included, no diffs that could drop a flag), addressed to the window
    /// number this scene owns. An unbound scene posts nothing: an untagged
    /// broadcast is absorbed by whichever strip is momentarily key, and a stale
    /// owner's tagged push freezes its own strip on an old set. `bind(to:)`
    /// replays this push.
    private func pushTabs() {
        guard let bound = boundNumber else { return }
        poster(TabStripBridge.update,
               [TabStripBridge.tabsKey: WindowRouting.stripPayload(lastTabItems),
                TabStripBridge.windowNumberKey: bound])
    }

    /// The scene's tabs changed: record the new snapshot and push it.
    func updateTabs(_ items: [TabItem]) {
        lastTabItems = items
        pushTabs()
    }

    /// One tagged `chalk.tabstrip.setVisible` post to the glue.
    func postVisibility(_ visible: Bool) {
        lastVisible = visible // recorded decision; see lastDividerX
        // An unbound scene posts nothing (see `pushTabs`); `replayStripState`
        // sends the recorded decision on bind.
        guard !isDetached, let bound = boundNumber else { return }
        poster(TabStripBridge.setVisible,
               [TabStripBridge.visibleKey: visible,
                TabStripBridge.windowNumberKey: bound])
    }

    /// One tagged `chalk.tabstrip.setFaded` post. `over` rides the payload when
    /// the fade is part of a composed transition (zen's motionStandard, or 0
    /// for instant placement): the strip never picks its own duration
    /// (docs/motion.md). A post with no duration keeps the glue's auto-hide
    /// default.
    func postFaded(_ faded: Bool, over duration: TimeInterval? = nil) {
        lastFaded = faded // recorded decision; see lastDividerX
        // An unbound scene posts nothing; `replayStripState` re-sends the fade
        // on bind.
        guard !isDetached, let bound = boundNumber else { return }
        var info: [String: Any] = [TabStripBridge.fadedKey: faded,
                                   TabStripBridge.windowNumberKey: bound]
        if let duration { info[TabStripBridge.durationKey] = duration }
        poster(TabStripBridge.setFaded, info)
    }

    /// Post the recorded scrim decision to this scene's window. Split from the
    /// root's `postStripScrim` so the bind replay can re-send a decision that
    /// its dedupe would swallow. An unbound scene posts nothing.
    func sendScrim() {
        guard !isDetached, let bound = boundNumber else { return }
        poster(TabStripBridge.setScrimmed,
               [TabStripBridge.scrimmedKey: host?.stripBridgeScrimmed ?? false,
                TabStripBridge.durationKey: ChromeScrim.fadeDuration,
                TabStripBridge.windowNumberKey: bound])
    }

    /// One tagged `chalk.tabstrip.leadingInset` post. `slideDuration` rides
    /// the payload when the change IS a sidebar slide (with the token's
    /// curve); the strip applies it to the slide's one big jump and stays
    /// instant for the dense small deltas of a live divider drag.
    func postLeadingInset(dividerX: CGFloat, outlineWidth: CGFloat,
                          slideDuration: TimeInterval?) {
        // The decision is recorded BEFORE the bound gate: an unbound test
        // root must still record what it decided, or the strip invariants
        // assert an unwritten seed instead of this code's answer.
        lastDividerX = dividerX
        // The strip filters on windowNumber, so a background window's layout
        // pass reaches only its own strip. An unbound scene posts nothing (see
        // `pushTabs`); binding replays the inset.
        guard !isDetached, let bound = boundNumber else { return }
        guard abs(dividerX - lastPostedDividerX) > 0.5
            || abs(outlineWidth - lastPostedOutlineWidth) > 0.5 else { return }
        lastPostedDividerX = dividerX
        lastPostedOutlineWidth = outlineWidth
        var info: [String: Any] = [TabStripBridge.dividerXKey: dividerX,
                                   TabStripBridge.outlineWidthKey: outlineWidth,
                                   TabStripBridge.windowNumberKey: bound]
        if let slideDuration {
            info[TabStripBridge.durationKey] = slideDuration
            // motionSidebar's curve (docs/motion.md)
            info[TabStripBridge.curveKey] = TabStripBridge.SlideCurve.easeOut.rawValue
        }
        poster(TabStripBridge.leadingInset, info)
    }

    /// The pointer entered or left the outline panel's resize grip; the glue
    /// pushes and pops `NSCursor.resizeLeftRight` (UIKit has no resize pointer
    /// shape).
    ///
    /// Not gated on being bound: the cursor is a momentary fact about a pointer
    /// inside exactly one window, so an untagged post leaves nothing stale.
    func postResizeCursor(inside: Bool) {
        guard !isDetached else { return }
        var info: [String: Any] = [TabStripBridge.insideKey: inside]
        if let bound = boundNumber {
            info[TabStripBridge.windowNumberKey] = bound
        }
        poster(TabStripBridge.shellResizeCursor, info)
    }

    // MARK: - Messages in

    /// The glue posted a pairing fact (`chalk.tabstrip.bind`). Bind on an
    /// exact match — the payload's UIWindow object IS this scene's window
    /// (KVC bridge), or its token equals the one this scene published while
    /// unbound. Everything else is another window's traffic: ignore it,
    /// except to make sure our own fallback token is out there while we
    /// remain unbound (covers re-pairing after a steal, where the
    /// connect-time publication was already retired).
    @objc private func handleTabStripBind(_ note: Notification) {
        // A detached test root never binds and never republishes a token —
        // bind traffic belongs to the real scene root alone.
        guard !isDetached else { return }
        let number = note.userInfo?[TabStripBridge.windowNumberKey] as? Int
        if note.userInfo?[TabStripBridge.isKeyFactKey] as? Bool == true, let number {
            // AppKit's direct key-window fact — the shell-routing signal.
            Self.appKitKeyWindowNumber = number
        }
        let window = host?.stripBridgeWindow
        let uiWindowMatches = window != nil
            && (note.userInfo?[TabStripBridge.uiWindowKey] as? UIWindow) === window
        Self.pairingLog.info("bind received: number=\(number ?? -1) hasObject=\(note.userInfo?[TabStripBridge.uiWindowKey] != nil) objectMatches=\(uiWindowMatches) payloadToken=\((note.userInfo?[TabStripBridge.tokenKey] as? String) ?? "nil") sceneToken=\(self.bindToken ?? "nil") boundNow=\(self.boundNumber ?? -1)")
        guard let target = WindowRouting.bindTarget(
            payloadWindowNumber: number,
            uiWindowMatches: uiWindowMatches,
            payloadToken: note.userInfo?[TabStripBridge.tokenKey] as? String,
            sceneToken: bindToken) else {
            if boundNumber == nil, let scene = window?.windowScene {
                publishBindToken(on: scene)
            }
            return
        }
        bind(to: target)
        // Full-screen state rides on the bind (see the glue's postBind): a
        // window restored straight into full screen announced it before this
        // scene was bound, so the routed post never landed — apply it now.
        if let fullScreen = note.userInfo?[TabStripBridge.isFullScreenKey] as? Bool {
            host?.stripBridgeApplyFullScreen(fullScreen)
        }
    }

    /// A strip asked for a re-push (just hosted, its window became key, or it
    /// rejected an update while still empty). Purely a re-push channel: replay
    /// if this scene owns the named number, otherwise no-op. Establishment
    /// belongs to the glue's `bind` post alone.
    @objc private func handleTabStripNeedsState(_ note: Notification) {
        guard isAddressedToBoundWindow(note) else { return }
        replayAll()
    }

    /// A click in the AppKit strip. Routed by `shouldHandle`, then handed to
    /// the root — the tab model is the root's, not this seam's.
    @objc private func handleTabStripAction(_ note: Notification) {
        guard shouldHandle(note),
              let action = (note.userInfo?[TabStripBridge.actionKey] as? String)
                .flatMap(TabStripBridge.Action.init(rawValue:)) else { return }
        let id = (note.userInfo?[TabStripBridge.idKey] as? String).flatMap(UUID.init)
        switch action {
        case .new:
            host?.stripBridgePerform(.new)
        case .select:
            if let id { host?.stripBridgePerform(.select(id)) }
        case .close:
            if let id { host?.stripBridgePerform(.close(id)) }
        case .move:
            if let id, let index = note.userInfo?[TabStripBridge.indexKey] as? Int {
                host?.stripBridgePerform(.move(id: id, to: index))
            }
        }
    }
}
