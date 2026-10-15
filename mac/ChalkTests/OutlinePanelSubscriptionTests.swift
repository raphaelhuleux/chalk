import XCTest
import ChalkKit
@testable import Chalk

/// Who is subscribed to the outline push: exactly the active tab, exactly
/// while the panel is open.
@MainActor
final class OutlinePanelSubscriptionTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for url in files { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    private func tempFile(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("outline-sub-\(UUID().uuidString)-\(name)")
        try! "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
        files.append(url)
        return url
    }

    private func hosted() -> (UIWindow, EditorContainerViewController) {
        let window = UIWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let container = EditorContainerViewController()
        window.rootViewController = container
        window.makeKeyAndVisible()
        container.view.layoutIfNeeded()
        return (window, container)
    }

    func testOpeningThePanelSubscribesTheActiveTab() {
        let (_, container) = hosted()
        container.open(url: tempFile("a.md"))
        XCTAssertEqual(container.outlineSubscriptionForTesting(tabAt: 0), false)
        container.setOutlinePanelVisible(true, animated: false)
        XCTAssertEqual(container.outlineSubscriptionForTesting(tabAt: 0), true)
        container.setOutlinePanelVisible(false, animated: false)
        XCTAssertEqual(container.outlineSubscriptionForTesting(tabAt: 0), false)
    }

    func testTabSwitchHandsTheSubscriptionOver() {
        let (_, container) = hosted()
        container.open(url: tempFile("a.md"))
        container.open(url: tempFile("b.md"))
        container.setOutlinePanelVisible(true, animated: false)
        XCTAssertEqual(container.outlineSubscriptionForTesting(tabAt: 0), false)
        XCTAssertEqual(container.outlineSubscriptionForTesting(tabAt: 1), true)
        container.activateTab(at: 0)
        XCTAssertEqual(container.outlineSubscriptionForTesting(tabAt: 0), true)
        XCTAssertEqual(container.outlineSubscriptionForTesting(tabAt: 1), false)
    }

    func testATabOpenedWhileThePanelIsOpenSubscribes() {
        let (_, container) = hosted()
        container.open(url: tempFile("a.md"))
        container.setOutlinePanelVisible(true, animated: false)
        container.open(url: tempFile("b.md"))
        XCTAssertEqual(container.outlineSubscriptionForTesting(tabAt: 0), false)
        XCTAssertEqual(container.outlineSubscriptionForTesting(tabAt: 1), true)
    }

    /// The header names the ACTIVE document and follows a tab switch.
    func testHeaderNamesTheActiveDocument() {
        let (_, container) = hosted()
        container.open(url: tempFile("a.md"))
        container.open(url: tempFile("b.md"))
        container.setOutlinePanelVisible(true, animated: false)
        XCTAssertTrue(container.outlinePanel.headerDocumentNameForTesting.hasSuffix("b.md"))
        container.activateTab(at: 0)
        XCTAssertTrue(container.outlinePanel.headerDocumentNameForTesting.hasSuffix("a.md"))
    }
}
