import AppKit
import ChalkKit

/// Inline rename: the row's name becomes a text field in place
/// (`LibraryCellView.beginEditing`), keeping the row's font, insets and glyph
/// so nothing jumps. The lifecycle lives on the controller because
/// `renamingNode` is row-paint input.
extension SidebarViewController {

    /// Enter edit mode on `node`. The "Empty" placeholder never renames.
    func beginRename(_ node: FileNode) {
        guard !Self.isEmptyPlaceholder(node) else { return }
        let previous = renamingNode
        renamingNode = node
        repaintRows(for: [previous, node])
    }

    /// Try to apply `name`. A rejected name keeps the editor open and shakes
    /// the row; the result says whether the editor closed.
    @discardableResult
    func commitRename(_ name: String) -> Bool {
        guard let node = renamingNode else { return true }
        let current = node.url.lastPathComponent
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rejection = FileNaming.validateRename(trimmed, current: current) {
            if rejection == .unchanged { cancelRename(); return true }
            shakeRenameField()
            return false
        }
        let destination = node.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        let started = moveFile(
            from: node.url, to: destination, actionName: "Rename", animated: true,
            completion: { [weak self] moved in
                // The move runs off the main thread, so a failure lands after the editor closed.
                guard !moved else { return }
                self?.showFileOpFailure("Couldn\u{2019}t rename \u{201C}\(node.url.lastPathComponent)\u{201D}.")
            })
        guard started else {
            // A sibling already owns the name, which `FileNaming` cannot see.
            shakeRenameField()
            return false
        }
        // Close now, not when the async move lands, which replaces the row.
        renamingNode = nil
        repaintRows(for: [node])
        return true
    }

    /// Leave edit mode with the name unchanged.
    func cancelRename() {
        guard let node = renamingNode else { return }
        renamingNode = nil
        repaintRows(for: [node])
    }

    func shakeRenameField() {
        guard let node = renamingNode, let row = rowForRename(node),
              let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false),
              let layer = rowView.layer else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -5, 5, -3, 3, 0]
        shake.duration = ChalkMetrics.motionFast * 2
        layer.add(shake, forKey: "chalk.rename.reject")
    }

    private func rowForRename(_ node: FileNode) -> Int? {
        guard let item = item(for: node) else { return nil }
        let row = outlineView.row(forItem: item)
        return row >= 0 ? row : nil
    }
}

#if DEBUG
extension SidebarViewController {
    var isRenamingForTesting: Bool { renamingNode != nil }
}
#endif
