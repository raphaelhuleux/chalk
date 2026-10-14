import Foundation

/// Pure decision logic for multi-window routing: which window binds to which
/// AppKit tab strip, which receiver accepts a bridge message, and which scene
/// handles a shell key command.
///
/// Routing keys on the NSWindow's `windowNumber`, never on `isKeyWindow`:
/// UIKit's key flag lags or points at a ghost scene after a multi-window
/// restore or a full-screen transition, which sent tab updates and Cmd+S to
/// the wrong window. Pairing is a fact the glue posts at toolbar attach
/// (`chalk.tabstrip.bind`, carrying the UIWindow via the UINSWindow KVC
/// bridge, or the scene's title token as the public-API fallback).
///
/// Also compiled into the glue bundle (mac/project.yml), so both halves run
/// these exact functions.
public enum WindowRouting {
    // MARK: Deterministic pairing

    /// The identity a scene should bind to for one `chalk.tabstrip.bind`
    /// post, or nil when the post carries no evidence FOR THIS SCENE: the
    /// payload's `uiWindow` is this scene's window, or its title token is
    /// this scene's. Purely local, so a ghost scene cannot change it.
    public static func bindTarget(
        payloadWindowNumber: Int?,
        uiWindowMatches: Bool,
        payloadToken: String?,
        sceneToken: String?
    ) -> Int? {
        guard let number = payloadWindowNumber else { return nil }
        if uiWindowMatches { return number }
        if let payloadToken, let sceneToken, payloadToken == sceneToken {
            return number
        }
        return nil
    }

    /// Title-token fallback: while unbound, a scene publishes
    /// `bindTitle(token:)` as its title and the glue posts the token back.
    /// The zero-width-space prefix keeps it from reading as a document name.
    public static let bindTitlePrefix = "\u{200B}chalk-bind:"

    public static func bindTitle(token: String) -> String { bindTitlePrefix + token }

    public static func bindToken(fromTitle title: String?) -> String? {
        guard let title, title.hasPrefix(bindTitlePrefix) else { return nil }
        let token = String(title.dropFirst(bindTitlePrefix.count))
        return token.isEmpty ? nil : token
    }

    /// Marks a window that must NOT get the editor's titlebar chrome.
    /// The glue attaches its strip to every primary scene window, which
    /// includes Settings; there an empty strip swallows titlebar drags.
    /// Invisible, and distinct from `bindTitlePrefix` (second char `c`).
    public static let noChromeTitlePrefix = "\u{200B}\u{2060}"

    public static func noChromeTitle(_ visible: String) -> String {
        noChromeTitlePrefix + visible
    }

    public static func isNoChromeTitle(_ title: String?) -> Bool {
        title?.hasPrefix(noChromeTitlePrefix) ?? false
    }

    /// AppKit-strip side: accept a `chalk.tabstrip.update` / `leadingInset`
    /// ONLY when it names this strip's own window. A key-window fallback for
    /// untagged messages let a momentarily-key strip absorb another window's
    /// tabs. The sender half of the rule: an unbound scene posts nothing
    /// (MacStripBridge.pushTabs).
    public static func stripShouldAccept(
        messageWindowNumber: Int?,
        stripWindowNumber: Int?
    ) -> Bool {
        guard let message = messageWindowNumber, let strip = stripWindowNumber
        else { return false }
        return message == strip
    }

    /// Strip-side self-heal: after a rejection, a strip that has NEVER
    /// rendered its own state solicits `needsState` from its owner.
    /// Only-while-empty keeps it terminating; soliciting on every rejection
    /// would ping-pong forever between two bound strips.
    public static func stripShouldSolicitOwnState(
        didAccept: Bool,
        hasEverAppliedOwnState: Bool
    ) -> Bool {
        !didAccept && !hasEverAppliedOwnState
    }

    /// UIKit-scene side: handle a strip action / needsState tagged
    /// `messageWindowNumber`? A bound scene handles only its own number. An
    /// unbound scene falls back to key only when NO scene owns the number,
    /// or a stale key flag would double-handle the owner's action.
    public static func sceneShouldHandle(
        messageWindowNumber: Int?,
        boundWindowNumber: Int?,
        messageNumberHasOwner: Bool,
        sceneWindowIsKey: Bool
    ) -> Bool {
        guard let message = messageWindowNumber else {
            // Untagged (no glue, or a pre-binding strip): key gate.
            return sceneWindowIsKey
        }
        if let bound = boundWindowNumber {
            return bound == message
        }
        return messageNumberHasOwner ? false : sceneWindowIsKey
    }

    /// Which scene a shell key command (Cmd+S, Cmd+W, …) acts on, as an
    /// index into parallel arrays: the scene bound to AppKit's key window
    /// (the authority on Mac), else the UIKit-key scene, else nil (the
    /// receiver handles it locally).
    public static func shellTargetIndex(
        boundToActiveWindow: [Bool],
        uikitKey: [Bool]
    ) -> Int? {
        if let index = boundToActiveWindow.firstIndex(of: true) { return index }
        return uikitKey.firstIndex(of: true)
    }
}

/// windowNumber → owning scene, last binder wins. Owners are held weakly so
/// a closed window's scene falls out on dealloc. Rebinding releases the
/// owner's previous number, so a scene is never authoritative for a window
/// it no longer services.
public final class WindowBindingRegistry {
    private final class WeakBox {
        weak var object: AnyObject?
        init(_ object: AnyObject) { self.object = object }
    }

    private var owners: [Int: WeakBox] = [:]

    public init() {}

    /// Bind `owner` to `number`, stealing it from any previous owner and
    /// releasing every other number `owner` held. Returns true when the
    /// binding changed; the caller MUST then push its full strip state.
    @discardableResult
    public func bind(_ owner: AnyObject, to number: Int) -> Bool {
        var changed = owners[number]?.object !== owner
        for (key, box) in owners where key != number {
            if box.object === owner || box.object == nil {
                owners.removeValue(forKey: key)
                if box.object === owner { changed = true }
            }
        }
        owners[number] = WeakBox(owner)
        return changed
    }

    public func hasOwner(_ number: Int) -> Bool { owners[number]?.object != nil }

    public func isOwner(_ candidate: AnyObject, of number: Int) -> Bool {
        owners[number]?.object === candidate
    }
}
