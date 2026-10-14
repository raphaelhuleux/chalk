import UIKit
import XCTest
@testable import Chalk

/// The one part of the Settings-window wiring that can be tested without a
/// GUI. Getting it wrong is not subtle — an editor built inside the Settings
/// window, or Cmd+, opening nothing — but the scene machinery around it only
/// runs in a real app, so the rule is isolated here.
final class SceneRoutingTests: XCTestCase {
    func testSettingsActivityRoutesToSettings() {
        XCTAssertEqual(
            SceneRouting.role(sessionRole: .windowApplication, activityTypes: [ChalkActivity.settingsType], restorationType: nil),
            .settings)
    }

    func testOrdinaryWindowRoutesToEditor() {
        XCTAssertEqual(
            SceneRouting.role(sessionRole: .windowApplication, activityTypes: [], restorationType: nil), .editor)
        XCTAssertEqual(
            SceneRouting.role(sessionRole: .windowApplication, activityTypes: [ChalkActivity.newWindowType], restorationType: nil),
            .editor)
        XCTAssertEqual(
            SceneRouting.role(sessionRole: .windowApplication, activityTypes: [], restorationType: ChalkActivity.windowType),
            .editor)
    }

    func testAStaleRestoredSettingsSessionStillRoutesToSettings() {
        // Settings never persists its restoration activity, but a session left
        // behind by an older build must not build an editor in that window.
        XCTAssertEqual(
            SceneRouting.role(sessionRole: .windowApplication, activityTypes: [], restorationType: ChalkActivity.settingsType),
            .settings)
    }

    func testSettingsWinsOverAnAccompanyingWindowActivity() {
        XCTAssertEqual(
            SceneRouting.role(
                sessionRole: .windowApplication,
                activityTypes: [ChalkActivity.newWindowType, ChalkActivity.settingsType],
                restorationType: ChalkActivity.windowType),
            .settings)
    }

    // MARK: - Roles the app does not support (2026-08-18)

    /// An external-display session is not a window: answering it with the
    /// editor configuration would put a SECOND, unrelated window on the
    /// monitor. The app declines every role that is not a window.
    func testExternalDisplaySessionIsDeclined() {
        XCTAssertEqual(
            SceneRouting.role(
                sessionRole: .windowExternalDisplayNonInteractive,
                activityTypes: [], restorationType: nil),
            .declined)
    }

    /// The gate is on the role, not on the activity: a restored window
    /// activity riding an external-display session must not smuggle an editor
    /// onto the monitor.
    func testExternalDisplayIsDeclinedEvenWithAWindowActivity() {
        XCTAssertEqual(
            SceneRouting.role(
                sessionRole: .windowExternalDisplayNonInteractive,
                activityTypes: [ChalkActivity.newWindowType],
                restorationType: ChalkActivity.windowType),
            .declined)
        XCTAssertEqual(
            SceneRouting.role(
                sessionRole: .windowExternalDisplayNonInteractive,
                activityTypes: [ChalkActivity.settingsType], restorationType: nil),
            .declined)
    }
}
