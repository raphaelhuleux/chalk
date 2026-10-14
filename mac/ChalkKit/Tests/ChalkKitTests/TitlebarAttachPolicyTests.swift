import XCTest
@testable import ChalkKit

/// The glue's attach-eligibility predicate (compiled into the glue bundle;
/// see the 2026-08-24 strip-attach P0). Every refusal reason is pinned
/// individually so a future edit that widens or narrows the predicate names
/// the window class it changed.
final class TitlebarAttachPolicyTests: XCTestCase {
    /// All facts as a primary scene window presents them.
    private func attach(
        isTitled: Bool = true,
        isMiniaturizable: Bool = true,
        isSheet: Bool = false,
        hasParent: Bool = false,
        hasNoChromeTitle: Bool = false,
        alreadyAttached: Bool = false
    ) -> Bool {
        TitlebarAttachPolicy.shouldAttach(
            isTitled: isTitled,
            isMiniaturizable: isMiniaturizable,
            isSheet: isSheet,
            hasParent: hasParent,
            hasNoChromeTitle: hasNoChromeTitle,
            alreadyAttached: alreadyAttached)
    }

    func testPrimarySceneWindowAttaches() {
        XCTAssertTrue(attach())
    }

    func testBorderlessWindowDoesNot() {
        XCTAssertFalse(attach(isTitled: false))
    }

    func testFormSheetStyleWindowDoesNot() {
        // Catalyst's Settings window: titled but never miniaturizable.
        XCTAssertFalse(attach(isMiniaturizable: false))
    }

    func testSheetDoesNot() {
        XCTAssertFalse(attach(isSheet: true))
    }

    func testChildWindowDoesNot() {
        XCTAssertFalse(attach(hasParent: true))
    }

    func testNoChromeTitledWindowDoesNot() {
        // WindowRouting.noChromeTitlePrefix windows keep the system titlebar.
        XCTAssertFalse(attach(hasNoChromeTitle: true))
    }

    func testAttachIsIdempotent() {
        XCTAssertFalse(attach(alreadyAttached: true))
    }

    /// The healing lanes re-evaluate on every window update: a window whose
    /// style mask arrives late must flip from refused to attached the moment
    /// the mask lands.
    func testLateArrivingStyleMaskFlipsTheAnswer() {
        XCTAssertFalse(attach(isMiniaturizable: false))
        XCTAssertTrue(attach(isMiniaturizable: true))
    }
}
