import AppKit
import ChalkKit

/// Where a lifted tab goes once it leaves its own row. The row keeps the mouse tracking (AppKit
/// sends every drag event to the view that took the mouse-down) and asks this at each move.
protocol TabDragCoordinator: AnyObject {
    func tabDragBegan(from strip: HeaderTabStrip)
    /// True when `windowPoint` is outside `strip`'s own row: the coordinator shows the feedback
    /// and the row shows no reorder.
    func tabDrag(_ id: UUID, from strip: HeaderTabStrip, movedTo windowPoint: NSPoint) -> Bool
    /// The drag ended; `committing` is false when it ended over its own row or was cancelled.
    /// True when the drop was the coordinator's (committed, or a release over nothing), so the
    /// row neither reorders nor selects.
    func tabDragEnded(_ id: UUID, committing: Bool) -> Bool
}

/// A window's tab drag between groups (docs/specs/2026-11-11-editor-groups-design.md): over
/// another group's row the tab inserts at the marker; over an editor it splits or joins by
/// VS Code's zones (`TabDropPolicy`); Escape cancels.
final class TabDragSession: TabDragCoordinator {
    /// Each row with the region that counts as it, in window coordinates: the band's height over
    /// the row's whole column, so a drag past the last name still reorders. Read once per drag:
    /// nothing moves the band or the panes while the mouse is held.
    var rows: () -> [(strip: HeaderTabStrip, region: CGRect)] = { [] }
    private var regions: [(strip: HeaderTabStrip, region: CGRect)] = []
    weak var editor: EditorContainerViewController?

    private enum Target {
        case row(HeaderTabStrip, index: Int)
        case editor(group: UUID, zone: TabDropPolicy.Zone)
    }
    private var target: Target?
    private var escapeMonitor: Any?
    private weak var sourceStrip: HeaderTabStrip?

    deinit { removeEscapeMonitor() }

    func tabDragBegan(from strip: HeaderTabStrip) {
        sourceStrip = strip
        regions = rows()
        target = nil
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, let source = self.sourceStrip else { return event }
            self.clearFeedback()
            source.cancelDrag()
            return nil
        }
    }

    func tabDrag(_ id: UUID, from strip: HeaderTabStrip, movedTo windowPoint: NSPoint) -> Bool {
        let rows = regions
        if let own = rows.first(where: { $0.strip === strip }), own.region.contains(windowPoint) {
            clearFeedback()
            return false
        }
        if let other = rows.first(where: { $0.strip !== strip && $0.region.contains(windowPoint) }) {
            editor?.showDropIndicator(nil)
            for row in rows where row.strip !== other.strip { row.strip.hideInsertion() }
            if let index = other.strip.showInsertion(atWindowPoint: windowPoint) {
                target = .row(other.strip, index: index)
            }
            return true
        }
        for row in rows { row.strip.hideInsertion() }
        if let drop = editor?.dropTarget(forTab: id, atWindowPoint: windowPoint) {
            editor?.showDropIndicator(drop.rect)
            target = .editor(group: drop.group, zone: drop.zone)
        } else {
            editor?.showDropIndicator(nil)
            target = nil
        }
        return true
    }

    func tabDragEnded(_ id: UUID, committing: Bool) -> Bool {
        removeEscapeMonitor()
        let committed = committing ? target : nil
        clearFeedback()
        sourceStrip = nil
        regions = []
        guard committing else { return false }
        switch committed {
        case .row(let row, let index)?:
            if let group = row.groupID { editor?.moveTab(id: id, toGroup: group, at: index) }
        case .editor(let group, let zone)?:
            editor?.dropTab(id: id, onGroup: group, zone: zone)
        case nil:
            break
        }
        return true
    }

    private func clearFeedback() {
        target = nil
        editor?.showDropIndicator(nil)
        for row in regions { row.strip.hideInsertion() }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}
