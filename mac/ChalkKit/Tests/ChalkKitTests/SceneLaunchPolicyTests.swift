import XCTest
@testable import ChalkKit

/// The launch policy is what keeps ghost scene sessions from turning into
/// windows: activity-less reconnects must never spawn extra Welcome tabs, and
/// the settle sweep must destroy every surplus empty window while never
/// touching one that holds content (P0 2026-07-24, blank editor on open).
final class SceneLaunchPolicyTests: XCTestCase {
    private let session = WindowSession(tabs: [], activeIndex: nil, isSidebarVisible: true)

    // MARK: - Per-connect content

    func testFirstSceneWithNoStateOpensWelcome() {
        XCTAssertEqual(
            SceneLaunchPolicy.initialContent(
                restoredSession: nil, isNewWindowRequest: false,
                hasURLContexts: false, isFirstApplicationScene: true,
                isRestorationDisabled: false),
            .openWelcome)
    }

    func testActivityLessReconnectBeyondFirstOpensEmptyNotWelcome() {
        XCTAssertEqual(
            SceneLaunchPolicy.initialContent(
                restoredSession: nil, isNewWindowRequest: false,
                hasURLContexts: false, isFirstApplicationScene: false,
                isRestorationDisabled: false),
            .openEmpty)
    }

    func testRestoredSessionAlwaysRestoresEvenBeyondFirst() {
        XCTAssertEqual(
            SceneLaunchPolicy.initialContent(
                restoredSession: session, isNewWindowRequest: false,
                hasURLContexts: false, isFirstApplicationScene: false,
                isRestorationDisabled: false),
            .restoreSession(session))
    }

    func testNewWindowRequestOpensEmpty() {
        XCTAssertEqual(
            SceneLaunchPolicy.initialContent(
                restoredSession: nil, isNewWindowRequest: true,
                hasURLContexts: false, isFirstApplicationScene: true,
                isRestorationDisabled: false),
            .openEmpty)
    }

    func testColdFinderOpenGetsEmptyWindowNotWelcomePlusFile() {
        XCTAssertEqual(
            SceneLaunchPolicy.initialContent(
                restoredSession: nil, isNewWindowRequest: false,
                hasURLContexts: true, isFirstApplicationScene: true,
                isRestorationDisabled: false),
            .openEmpty)
    }

    func testRestoredSessionWinsOverURLContexts() {
        // Warm relaunch with a Finder file: restore the window, the URL lands
        // as one more tab on top (SceneDelegate's urlContexts loop).
        XCTAssertEqual(
            SceneLaunchPolicy.initialContent(
                restoredSession: session, isNewWindowRequest: false,
                hasURLContexts: true, isFirstApplicationScene: true,
                isRestorationDisabled: false),
            .restoreSession(session))
    }

    func testRestorationDisabledGivesWelcomeOnlyColdStart() {
        // The audit harness and UI tests assume exactly one Welcome window.
        XCTAssertEqual(
            SceneLaunchPolicy.initialContent(
                restoredSession: session, isNewWindowRequest: false,
                hasURLContexts: false, isFirstApplicationScene: true,
                isRestorationDisabled: true),
            .openWelcome)
        XCTAssertEqual(
            SceneLaunchPolicy.initialContent(
                restoredSession: session, isNewWindowRequest: false,
                hasURLContexts: false, isFirstApplicationScene: false,
                isRestorationDisabled: true),
            .openEmpty)
    }

    // MARK: - Launch-settle sweep

    func testSingleSceneIsNeverSwept() {
        XCTAssertEqual(SceneLaunchPolicy.launchSweepVictims(openTabCounts: [0]), [])
    }

    func testEmptyScenesAreSweptWhenContentExists() {
        XCTAssertEqual(
            SceneLaunchPolicy.launchSweepVictims(openTabCounts: [0, 2, 0, 1]),
            [0, 2])
    }

    func testAllEmptyKeepsExactlyOne() {
        XCTAssertEqual(
            SceneLaunchPolicy.launchSweepVictims(openTabCounts: [0, 0, 0]),
            [1, 2])
    }

    func testNoEmptiesSweepsNothing() {
        XCTAssertEqual(
            SceneLaunchPolicy.launchSweepVictims(openTabCounts: [1, 3]), [])
    }
}
