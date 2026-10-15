import AppKit
import ChalkKit

/// Library file operations from the row context menu. Like `moveFile`:
/// failures always go through `showFileOpFailure`, and every operation
/// registers undo with `fileUndoManager`.
extension SidebarViewController {

    // MARK: - Duplicate

    /// Copy `node` beside itself as `name 2.ext`. Undo trashes the copy rather
    /// than deleting it. The name probe runs off-main too: in an iCloud
    /// Location each `fileExists` crosses the sync layer.
    func duplicate(_ node: FileNode) {
        let source = node.url
        let directory = source.deletingLastPathComponent()
        let isDirectory = node.isDirectory
        runFileWork { () throws -> (String, URL) in
            let name = FileNaming.duplicateName(for: source.lastPathComponent) { candidate in
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
            }
            let destination = directory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: destination)
            return (name, destination)
        } then: { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.showFileOpFailure("Couldn\u{2019}t duplicate \u{201C}\(source.lastPathComponent)\u{201D}: \(error.localizedDescription)")
            case .success(let (name, destination)):
                self.reloadEveryLibrary(animated: true)
                self.fileUndoManager.registerUndo(withTarget: self) { target in
                    target.moveToTrash(FileNode(url: destination, name: name, isDirectory: isDirectory))
                }
                self.fileUndoManager.setActionName("Duplicate")
                self.focusTree()
            }
        }
    }

    // MARK: - Move to Trash

    /// Trash `node` with no confirmation; Cmd+Z restores it.
    ///
    /// `FileManager.trashItem` hands back where the item landed, which is what
    /// the undo moves back. The Catalyst shell's undo was recorded failing on
    /// this path (docs/known-failing-tests.md, 2026-08-23); the resulting URL
    /// is checked here and a nil one registers no undo rather than a dead one.
    func moveToTrash(_ node: FileNode) {
        let original = node.url
        let isDirectory = node.isDirectory
        runFileWork { () throws -> URL? in
            var trashed: NSURL?
            try FileManager.default.trashItem(at: original, resultingItemURL: &trashed)
            return trashed as URL?
        } then: { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.showFileOpFailure("Couldn\u{2019}t move \u{201C}\(original.lastPathComponent)\u{201D} to the Trash: \(error.localizedDescription)")
            case .success(let trashedURL):
                self.reloadEveryLibrary(animated: true)
                if let trashedURL {
                    self.fileUndoManager.registerUndo(withTarget: self) { target in
                        target.restore(from: trashedURL, to: original, isDirectory: isDirectory)
                    }
                    self.fileUndoManager.setActionName("Move to Trash")
                }
                self.focusTree()
            }
        }
    }

    /// Undo of a trash. Registers the redo, so Cmd+Shift+Z trashes it again.
    private func restore(from trashedURL: URL, to original: URL, isDirectory: Bool) {
        runFileWork {
            try FileManager.default.moveItem(at: trashedURL, to: original)
        } then: { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                self.showFileOpFailure("Couldn\u{2019}t restore \u{201C}\(original.lastPathComponent)\u{201D} from the Trash: \(error.localizedDescription)")
                return
            }
            self.reloadEveryLibrary(animated: true)
            self.fileUndoManager.registerUndo(withTarget: self) { target in
                target.moveToTrash(FileNode(
                    url: original, name: original.lastPathComponent, isDirectory: isDirectory))
            }
        }
    }

    // MARK: - Copy

    /// Put the file itself on the pasteboard, so Cmd+V in Finder pastes a real file.
    func copyToPasteboard(_ node: FileNode) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.writeObjects([node.url as NSURL]) {
            showFileOpFailure("Couldn\u{2019}t copy \u{201C}\(node.url.lastPathComponent)\u{201D}.")
        }
    }

    // MARK: - Row context menu

    /// The right-click menu for a file or folder row, in groups separated so
    /// "Move to Trash" stands apart. Order is part of the design: open
    /// actions, edit actions, create actions, then the destructive one last.
    func rowMenu(for node: FileNode) -> NSMenu {
        // On a file row, New File/New Folder target its folder, as drag-drop does.
        let container = node.isDirectory ? node.url : node.url.deletingLastPathComponent()

        // An asset row (image/PDF) cannot open in a tab; it only previews.
        let documentOpen: [NSMenuItem] = [
            MenuActionItem(title: "Open") { [weak self] in self?.onOpenFile?(node.url) },
            MenuActionItem(title: "Open in New Tab") { [weak self] in self?.onOpenFileInNewTab?(node.url) },
            MenuActionItem(title: "Open in New Window") { [weak self] in self?.onOpenFileInNewWindow?(node.url) },
        ]
        let assetOpen: [NSMenuItem] = [
            MenuActionItem(title: "Preview") { [weak self] in self?.onPreviewFile?(node.url) },
        ]
        let open: [NSMenuItem]
        if node.isDirectory {
            open = []
        } else {
            open = FileTree.kind(of: node.url) == .asset ? assetOpen : documentOpen
        }

        let edit: [NSMenuItem] = [
            MenuActionItem(title: "Rename") { [weak self] in self?.beginRename(node) },
            MenuActionItem(title: "Duplicate") { [weak self] in self?.duplicate(node) },
            MenuActionItem(title: "Copy") { [weak self] in self?.copyToPasteboard(node) },
            MenuActionItem(title: "Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            },
        ]

        let trash: [NSMenuItem] = [
            Self.destructive(MenuActionItem(title: "Move to Trash") { [weak self] in self?.moveToTrash(node) }),
        ]

        let groups: [[NSMenuItem]] = node.isDirectory
            ? [createItems(in: container), edit, trash]
            : [open, edit, createItems(in: container), trash]

        let menu = NSMenu()
        for group in groups where !group.isEmpty {
            if menu.items.isEmpty == false { menu.addItem(.separator()) }
            for item in group { menu.addItem(item) }
        }
        return menu
    }
}

// MARK: - Where sidebar file work runs

extension SidebarViewController {
    /// Tell every window's Library, then reload this one now. Post first: the
    /// broadcast schedules a coalesced reload here too, which this call then replaces.
    func reloadEveryLibrary(animated: Bool) {
        NotificationCenter.default.post(name: .chalkLibraryDidChange, object: nil)
        scheduleReload(animated: animated, delay: 0)
    }

    /// One serial queue for every sidebar file operation except moves
    /// (`CoordinatedFileMove.queue`), so operations cannot reorder. Off main
    /// because in an iCloud folder `copyItem` materializes dataless files,
    /// `trashItem` is a daemon round trip and each `fileExists` crosses the sync layer.
    static let fileWorkQueue = DispatchQueue(
        label: "com.huleux.chalk.sidebar-fileops", qos: .userInitiated)

    #if DEBUG
    /// Whether the last `runFileWork` body ran on main (SidebarFileWorkThreadingTests).
    /// Read only after the completion lands, which orders it after the write.
    static var lastFileWorkRanOnMainThread: Bool?
    #endif

    /// Run `work` off the main thread; report its result, or what it threw, on main.
    func runFileWork<Value>(
        _ work: @escaping () throws -> Value,
        then finish: @escaping (Result<Value, Error>) -> Void
    ) {
        Self.fileWorkQueue.async { [weak self] in
            #if DEBUG
            Self.lastFileWorkRanOnMainThread = Thread.isMainThread
            #endif
            let result = Result { try work() }
            DispatchQueue.main.async {
                finish(result)
                self?.notifyFileWorkFinished()
            }
        }
    }

    func notifyFileWorkFinished() {
        #if DEBUG
        onFileWorkFinishedForTesting?()
        #endif
    }
}
