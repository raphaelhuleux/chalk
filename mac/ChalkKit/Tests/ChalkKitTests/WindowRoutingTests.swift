import XCTest
@testable import ChalkKit

/// The pure multi-window routing contracts (U6 2026-07-24; pairing redesigned
/// U9 same day): deterministic NSWindow↔UIWindow pairing posted as a fact by
/// the glue (`chalk.tabstrip.bind`, matched here via `WindowRouting.bindTarget`)
/// and identity-matched bridge messages. The old key-simultaneity handshake,
/// verify-then-steal, and elimination-census tests died with those heuristics.
///
/// These live in ChalkKit because `WindowRouting` does: the AppKit glue
/// compiles the same file in and runs these exact predicates, where it used to
/// carry hand mirrors of them. The tests that need app-target types
/// (`stripPayload`, the two-window save) stay in ChalkTests.
final class WindowRoutingTests: XCTestCase {
    // MARK: - Deterministic pairing (bind-notification matching)

    func testBindMatchesOnUIWindowObjectIdentity() {
        XCTAssertEqual(
            WindowRouting.bindTarget(
                payloadWindowNumber: 7, uiWindowMatches: true,
                payloadToken: nil, sceneToken: nil),
            7, "the KVC bridge fact — payload's UIWindow IS this scene's window — binds")
        XCTAssertEqual(
            WindowRouting.bindTarget(
                payloadWindowNumber: 7, uiWindowMatches: true,
                payloadToken: "other", sceneToken: "mine"),
            7, "object identity is the strongest evidence; a stray token cannot veto it")
    }

    func testBindMatchesOnPublishedToken() {
        XCTAssertEqual(
            WindowRouting.bindTarget(
                payloadWindowNumber: 9, uiWindowMatches: false,
                payloadToken: "abc-123", sceneToken: "abc-123"),
            9, "the title-token fallback lane binds on exact token equality")
    }

    func testBindIgnoresMismatchedEvidence() {
        XCTAssertNil(
            WindowRouting.bindTarget(
                payloadWindowNumber: 7, uiWindowMatches: false,
                payloadToken: "theirs", sceneToken: "mine"),
            "another window's token proves nothing for this scene")
        XCTAssertNil(
            WindowRouting.bindTarget(
                payloadWindowNumber: 7, uiWindowMatches: false,
                payloadToken: nil, sceneToken: "mine"),
            "a number-only post (shell-routing fact) never binds anyone")
        XCTAssertNil(
            WindowRouting.bindTarget(
                payloadWindowNumber: 7, uiWindowMatches: false,
                payloadToken: "abc", sceneToken: nil),
            "a scene that never published a token must not match one")
        XCTAssertNil(
            WindowRouting.bindTarget(
                payloadWindowNumber: nil, uiWindowMatches: true,
                payloadToken: nil, sceneToken: nil),
            "no windowNumber, nothing to bind to")
    }

    func testRePairReleasesThePreviousNumber() {
        // A window is torn down and its scene re-pairs with a fresh NSWindow
        // (or a recycled number): the registry must not keep the scene
        // "authoritative" for the number it left behind.
        let registry = WindowBindingRegistry()
        let scene = NSObject()
        registry.bind(scene, to: 7)
        XCTAssertEqual(
            WindowRouting.bindTarget(
                payloadWindowNumber: 9, uiWindowMatches: true,
                payloadToken: nil, sceneToken: nil),
            9, "the glue's re-post for the new window matches the same scene")
        XCTAssertTrue(registry.bind(scene, to: 9),
                      "re-pairing is a change — the owner must push its full state")
        XCTAssertTrue(registry.isOwner(scene, of: 9))
        XCTAssertFalse(registry.hasOwner(7),
                       "the old number is released, free for whoever genuinely owns it next")
    }

    func testGhostScenePresenceChangesNothing() {
        // The R2 pathology under the OLD design: a zombie scene inflated the
        // unbound-scene census and elimination refused, leaving a real strip
        // empty forever. bindTarget takes no census — each scene's decision
        // is purely its own evidence, so a ghost pairs with nothing and the
        // real scene still binds.
        let realSceneDecision = WindowRouting.bindTarget(
            payloadWindowNumber: 7, uiWindowMatches: true,
            payloadToken: nil, sceneToken: nil)
        let ghostSceneDecision = WindowRouting.bindTarget(
            payloadWindowNumber: 7, uiWindowMatches: false,
            payloadToken: nil, sceneToken: "ghost-token-nobody-posted")
        XCTAssertEqual(realSceneDecision, 7,
                       "the paired scene binds regardless of how many ghosts exist")
        XCTAssertNil(ghostSceneDecision,
                     "the ghost matches nothing and cannot poison the binding")
    }

    func testBindTitleTokenRoundTrip() {
        let title = WindowRouting.bindTitle(token: "abc-123")
        XCTAssertTrue(title.hasPrefix("\u{200B}"),
                      "zero-width prefix keeps the token title invisible-adjacent")
        XCTAssertEqual(WindowRouting.bindToken(fromTitle: title), "abc-123")
        XCTAssertNil(WindowRouting.bindToken(fromTitle: "My Document.md"),
                     "a real document title never parses as a token")
        XCTAssertNil(WindowRouting.bindToken(fromTitle: nil))
        XCTAssertNil(WindowRouting.bindToken(fromTitle: WindowRouting.bindTitle(token: "")),
                     "an empty token is no token")
    }

    // MARK: - Binding registry (bind → re-push, double-bind resolution)

    func testBindingChangeDemandsRePushAndRefreshDoesNot() {
        let registry = WindowBindingRegistry()
        let scene = NSObject()
        XCTAssertTrue(registry.bind(scene, to: 7),
                      "first bind is a change — the owner must push its full state")
        XCTAssertFalse(registry.bind(scene, to: 7),
                       "refreshing an existing binding demands no push")
        XCTAssertTrue(registry.bind(scene, to: 9),
                      "migrating to a new window is a change — push again")
        XCTAssertFalse(registry.hasOwner(7),
                       "rebinding releases the previous number (the stale 7→scene entry kept a mis-bound scene authoritative in R1)")
    }

    func testSameNumberDoubleBindLastBinderWinsAndLoserGoesSilent() {
        let registry = WindowBindingRegistry()
        let first = NSObject()
        let second = NSObject()
        registry.bind(first, to: 7)
        XCTAssertTrue(registry.bind(second, to: 7),
                      "stealing is a change — the NEW owner must push, so the strip never keeps the loser's set")
        XCTAssertTrue(registry.isOwner(second, of: 7))
        XCTAssertFalse(registry.isOwner(first, of: 7),
                       "the loser is no longer authoritative: its pushes stop entirely (unbound scenes post nothing) instead of tagging a window it lost")
    }

    func testClosedWindowsSceneFallsOutOfTheRegistry() {
        let registry = WindowBindingRegistry()
        autoreleasepool {
            let dying = NSObject()
            registry.bind(dying, to: 7)
            XCTAssertTrue(registry.hasOwner(7))
        }
        XCTAssertFalse(registry.hasOwner(7),
                       "weak owners: a recycled windowNumber must start unowned")
    }

    // MARK: - Strip-side acceptance (the glue runs this same function)

    func testStripAcceptsOnlyItsOwnWindowsMessages() {
        // Identity decides, nothing else.
        XCTAssertTrue(WindowRouting.stripShouldAccept(
            messageWindowNumber: 7, stripWindowNumber: 7),
            "a background strip must accept ITS OWN window's update (restore fix)")
        // The foreign-rejection contract behind R1: a rejected update leaves
        // the strip's last own state on screen — it must never be adopted.
        XCTAssertFalse(WindowRouting.stripShouldAccept(
            messageWindowNumber: 7, stripWindowNumber: 9),
            "a strip must never absorb another window's tab set (U6)")
        // U8 (was: key-window fallback): an update the strip cannot associate
        // with its own windowNumber is never rendered. The untagged broadcast
        // no longer exists sender-side; rejecting it here is defense in depth
        // against the R2 restore absorption.
        XCTAssertFalse(WindowRouting.stripShouldAccept(
            messageWindowNumber: nil, stripWindowNumber: 7))
        XCTAssertFalse(WindowRouting.stripShouldAccept(
            messageWindowNumber: 7, stripWindowNumber: nil),
            "a strip whose window is gone accepts nothing")
    }

    func testStripSolicitsFreshHandshakeOnlyWhileItHasNoOwnState() {
        // R2 self-heal: an empty strip that sees a foreign push asks for its
        // own state instead of adopting the payload...
        XCTAssertTrue(WindowRouting.stripShouldSolicitOwnState(
            didAccept: false, hasEverAppliedOwnState: false))
        // ...but once it has own state, rejections stay silent — soliciting on
        // every rejection would ping-pong between two bound strips forever.
        XCTAssertFalse(WindowRouting.stripShouldSolicitOwnState(
            didAccept: false, hasEverAppliedOwnState: true))
        XCTAssertFalse(WindowRouting.stripShouldSolicitOwnState(
            didAccept: true, hasEverAppliedOwnState: false))
    }

    // MARK: - Scene-side acceptance

    func testBoundSceneHandlesExactlyItsOwnStripsMessages() {
        XCTAssertTrue(WindowRouting.sceneShouldHandle(
            messageWindowNumber: 7, boundWindowNumber: 7,
            messageNumberHasOwner: true, sceneWindowIsKey: false),
            "identity match wins even while the UIKit key flag lags")
        XCTAssertFalse(WindowRouting.sceneShouldHandle(
            messageWindowNumber: 7, boundWindowNumber: 9,
            messageNumberHasOwner: true, sceneWindowIsKey: true),
            "a scene bound to another window must not steal actions, key or not")
    }

    func testUnboundSceneKeyFallbackYieldsToAnOwner() {
        XCTAssertFalse(WindowRouting.sceneShouldHandle(
            messageWindowNumber: 7, boundWindowNumber: nil,
            messageNumberHasOwner: true, sceneWindowIsKey: true),
            "when some scene owns the number, a stale-key scene must not double-handle")
        XCTAssertTrue(WindowRouting.sceneShouldHandle(
            messageWindowNumber: 7, boundWindowNumber: nil,
            messageNumberHasOwner: false, sceneWindowIsKey: true),
            "ownerless tagged message: key fallback keeps pre-binding clicks working")
        XCTAssertFalse(WindowRouting.sceneShouldHandle(
            messageWindowNumber: 7, boundWindowNumber: nil,
            messageNumberHasOwner: false, sceneWindowIsKey: false))
    }

    func testUntaggedMessageKeepsLegacyKeyGate() {
        XCTAssertTrue(WindowRouting.sceneShouldHandle(
            messageWindowNumber: nil, boundWindowNumber: nil,
            messageNumberHasOwner: false, sceneWindowIsKey: true))
        XCTAssertFalse(WindowRouting.sceneShouldHandle(
            messageWindowNumber: nil, boundWindowNumber: nil,
            messageNumberHasOwner: false, sceneWindowIsKey: false))
    }

    // MARK: - Shell command target resolution

    func testShellTargetPrefersAppKitBoundKeyWindowOverStaleUIKitKeyFlag() {
        // The live Cmd+S defect: UIKit's key flag pointed at window A (index
        // 0) while the user was demonstrably in window B (index 1, bound to
        // the AppKit key window). Identity must win.
        XCTAssertEqual(
            WindowRouting.shellTargetIndex(
                boundToActiveWindow: [false, true], uikitKey: [true, false]),
            1)
    }

    func testShellTargetFallsBackToUIKitKeyThenLocal() {
        XCTAssertEqual(
            WindowRouting.shellTargetIndex(
                boundToActiveWindow: [false, false], uikitKey: [false, true]),
            1, "no glue binding (glue missing): UIKit key decides")
        XCTAssertNil(
            WindowRouting.shellTargetIndex(
                boundToActiveWindow: [false, false], uikitKey: [false, false]),
            "no evidence at all: handle locally (unchanged single-window behavior)")
    }
}
