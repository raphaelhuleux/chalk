import XCTest
import ChalkKit
@testable import ChalkMac

// MARK: - Awaiting sidebar file work

extension XCTestCase {
    /// Drive a sidebar file operation and wait for it to finish.
    ///
    /// Every sidebar mutation runs off the main thread, so a test that asserts
    /// on-disk state right after calling one would be racing work still in
    /// flight, and a `tearDown` that deletes the fixture under a live
    /// operation is worse than a wrong assertion. `body` runs inside the wait,
    /// so a test can also assert what is true WHILE the work is in flight.
    @MainActor
    func awaitFileWork(
        on sidebar: SidebarViewController,
        timeout: TimeInterval = 5,
        _ body: () -> Void
    ) {
        let done = expectation(description: "sidebar file work finished")
        // An operation reports once, but an undo registered by one operation
        // can report again while this expectation is still current.
        done.assertForOverFulfill = false
        sidebar.onFileWorkFinishedForTesting = { done.fulfill() }
        body()
        wait(for: [done], timeout: timeout)
        sidebar.onFileWorkFinishedForTesting = nil
    }

    /// The same, for the grandchild reads a folder expansion kicks off. The
    /// expansion itself stays synchronous (the build appends one level ahead
    /// of every collapsed folder), so this waits only for the chevrons on the
    /// subfolders it revealed.
    @MainActor
    func awaitExpansionWork(
        on sidebar: SidebarViewController,
        timeout: TimeInterval = 5,
        _ body: () -> Void
    ) {
        let done = expectation(description: "sidebar expansion work finished")
        done.assertForOverFulfill = false
        sidebar.onExpansionWorkFinishedForTesting = { done.fulfill() }
        body()
        wait(for: [done], timeout: timeout)
        sidebar.onExpansionWorkFinishedForTesting = nil
    }

    /// Probe once: some sandboxes have no Trash for the volume.
    func canTrash(in root: URL) -> Bool {
        let probe = root.appendingPathComponent("trash-probe")
        guard (try? Data().write(to: probe)) != nil else { return false }
        var resulting: NSURL?
        let ok = (try? FileManager.default.trashItem(at: probe, resultingItemURL: &resulting)) != nil
        if let resulting = resulting as URL? { try? FileManager.default.removeItem(at: resulting) }
        try? FileManager.default.removeItem(at: probe)
        return ok
    }

    /// Fire a menu item the way the menu would.
    func perform(_ item: NSMenuItem) {
        guard let action = item.action else { return }
        _ = NSApp.sendAction(action, to: item.target, from: item)
    }

    /// Titles in menu order, separators dropped, so a test asserts the menu's shape.
    func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    func item(in menu: NSMenu, titled title: String) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }
}

/// A sidebar hosted in a window of `size`, loaded, reloaded and laid out.
@MainActor
func makeHostedSidebar(locations: [Location],
                       size: CGSize = CGSize(width: 320, height: 600)) -> (SidebarViewController, NSWindow) {
    let sidebar = SidebarViewController()
    sidebar.locationsProvider = { locations }
    let window = NSWindow.hostedForTesting(frame: CGRect(origin: .zero, size: size))
    window.rootViewController = sidebar
    window.isHidden = false
    sidebar.loadViewIfNeeded()
    sidebar.reload()
    settleSidebar(sidebar, window)
    return (sidebar, window)
}

@MainActor
func settleSidebar(_ sidebar: SidebarViewController, _ window: NSWindow) {
    window.layoutIfNeeded()
    sidebar.view.layoutSubtreeIfNeeded()
    sidebar.outlineViewForTesting.layoutSubtreeIfNeeded()
}

@MainActor
func dismantleHostedSidebar(_ window: NSWindow?) {
    window?.isHidden = true
    window?.rootViewController = nil
}
