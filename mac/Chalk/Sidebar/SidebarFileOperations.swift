import UIKit
import ChalkKit

/// Library file operations from the row context menu. Like `moveFile`: failures always go through
/// `showFileOpFailure`, and every operation registers undo with `fileUndoManager`.
extension SidebarViewController {

    // MARK: - Duplicate

    /// Copy `node` beside itself as `name 2.ext`. Undo trashes the copy rather than deleting it. The
    /// name probe runs off-main too: in an iCloud Location each `fileExists` crosses the sync layer.
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
                self.becomeFirstResponder()
            }
        }
    }

    // MARK: - Move to Trash

    /// Trash `node` with no confirmation; Cmd+Z restores it.
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
                // Without a resulting URL (the API allows nil) there is nothing to undo from, so
                // register no undo rather than one that does nothing.
                if let trashedURL {
                    self.fileUndoManager.registerUndo(withTarget: self) { target in
                        target.restore(from: trashedURL, to: original, isDirectory: isDirectory)
                    }
                    self.fileUndoManager.setActionName("Move to Trash")
                }
                self.becomeFirstResponder()
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

    /// Put the file itself on the pasteboard, so Cmd+V in Finder or Files pastes a real file.
    func copyToPasteboard(_ node: FileNode) {
        guard let provider = NSItemProvider(contentsOf: node.url) else {
            showFileOpFailure("Couldn\u{2019}t copy \u{201C}\(node.url.lastPathComponent)\u{201D}.")
            return
        }
        UIPasteboard.general.itemProviders = [provider]
    }
}

extension SidebarViewController {

    // MARK: - Row context menu

    /// The right-click menu for a file or folder row, in inline groups so separators keep "Move to
    /// Trash" apart.
    func rowMenu(for node: FileNode) -> UIMenu {
        // On a file row, New File/New Folder target its folder, as drag-drop does.
        let container = node.isDirectory ? node.url : node.url.deletingLastPathComponent()

        // An asset row (image/PDF) cannot open in a tab; it only previews.
        let documentOpen: [UIMenuElement] = [
            UIAction(title: "Open", image: UIImage(systemName: "arrow.up.forward.square")) {
                [weak self] _ in self?.onOpenFile?(node.url)
            },
            UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.rectangle.on.rectangle")) {
                [weak self] _ in self?.onOpenFileInNewTab?(node.url)
            },
            UIAction(title: "Open in New Window", image: UIImage(systemName: "macwindow.badge.plus")) {
                [weak self] _ in self?.onOpenFileInNewWindow?(node.url)
            },
        ]
        let assetOpen: [UIMenuElement] = [
            UIAction(title: "Preview", image: UIImage(systemName: "eye")) {
                [weak self] _ in self?.onPreviewFile?(node.url)
            },
        ]

        let open: [UIMenuElement]
        if node.isDirectory {
            open = []
        } else {
            open = FileTree.kind(of: node.url) == .asset ? assetOpen : documentOpen
        }

        let edit: [UIMenuElement] = [
            UIAction(title: "Rename", image: UIImage(systemName: "pencil")) {
                [weak self] _ in self?.beginRename(node)
            },
            UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) {
                [weak self] _ in self?.duplicate(node)
            },
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) {
                [weak self] _ in self?.copyToPasteboard(node)
            },
            UIAction(title: "Copy Path", image: UIImage(systemName: "text.quote")) { _ in
                UIPasteboard.general.string = node.url.path
            },
        ]

        let trash: [UIMenuElement] = [
            UIAction(title: "Move to Trash", image: UIImage(systemName: "trash"),
                     attributes: .destructive) { [weak self] _ in self?.moveToTrash(node) },
        ]

        let groups: [[UIMenuElement]] = node.isDirectory
            ? [createActions(in: container), edit, trash]
            : [open, edit, createActions(in: container), trash]

        return UIMenu(children: groups.filter { !$0.isEmpty }.map {
            UIMenu(title: "", options: .displayInline, children: $0)
        })
    }
}

// MARK: - Where sidebar file work runs

extension SidebarViewController {
    /// Tell every window's Library, then reload this one now. Post first: the broadcast schedules a
    /// coalesced reload here too, which this call then replaces.
    func reloadEveryLibrary(animated: Bool) {
        NotificationCenter.default.post(name: .chalkLibraryDidChange, object: nil)
        scheduleReload(animated: animated, delay: 0)
    }

    /// One serial queue for every sidebar file operation except moves (`CoordinatedFileMove.queue`),
    /// so operations cannot reorder. Off main because in an iCloud folder `copyItem` materializes
    /// dataless files, `trashItem` is a daemon round trip and each `fileExists` crosses the sync layer.
    static let fileWorkQueue = DispatchQueue(
        label: "com.huleux.chalk.sidebar-fileops", qos: .userInitiated)

    #if DEBUG
    /// Whether the last `runFileWork` body ran on main (SidebarFileWorkThreadingTests). Read
    /// only after the completion lands, which orders it after the write.
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
