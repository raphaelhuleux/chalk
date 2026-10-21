import AppKit
import ChalkKit
import os

/// os.Logger, not NSLog: file names are personal data, and .private interpolations are redacted in release.
private let log = Logger(subsystem: "com.huleux.chalk", category: "doc")

protocol DocumentControllerDelegate: AnyObject {
    func documentController(_ controller: DocumentController, didChangeDirty isDirty: Bool)
    /// A draft was asked to save: the host picks a destination, calls `bindDraft(to:writtenText:)`, then
    /// reports the outcome. `completion(false)` on cancel/failure keeps confirm-close's tab open.
    func documentController(_ controller: DocumentController,
                            needsSaveDestination completion: @escaping (Bool) -> Void)
    /// A file-backed save confirmed a write of real changes (fires in the write's completion). Lets the
    /// host commit the tab out of "preview"; a clean flush doesn't fire, or every saveAll would commit them all.
    func documentControllerDidSave(_ controller: DocumentController)
    /// The user saved THIS document on purpose (Cmd+S). Fires before the write, even with nothing to write:
    /// the intent alone pins the tab out of "preview".
    func documentControllerDidRequestExplicitSave(_ controller: DocumentController)
    /// An explicit save (Cmd+S) of a file-backed document finished, written or already clean.
    /// The compile-on-save hook: it fires after the bytes are on disk.
    func documentController(_ controller: DocumentController, didFinishExplicitSave succeeded: Bool)
    /// `url` changed on disk since our last read/write and is about to be overwritten (or an iCloud
    /// conflict version lost). The losing version was copied to `backupAt` (the `.conflict.` sibling, else
    /// `RecoveryStore.conflictCopiesDirectory`), or nil when both copies failed: the host must word the
    /// alert by what actually happened. The write proceeds regardless; the copy is the safety floor.
    func documentController(_ controller: DocumentController,
                            hasSaveConflictAt url: URL, backupAt backupURL: URL?)
    /// A save to `url` failed (disk full, revoked scope, iCloud error). The
    /// buffer is kept dirty for retry; the host should surface the failure.
    func documentController(_ controller: DocumentController, didFailSaveTo url: URL)
    /// Opening `url` failed: the editor was never seeded. Unsurfaced, the tab reads as a permanent blank
    /// (see docs/issues/2026-07-24-blank-editor-on-open.md); the host should offer retry or close.
    func documentController(_ controller: DocumentController, didFailToOpen url: URL)
    /// A web-layer shell command that isn't a document concern (e.g. "toggle-outline": a focused webview
    /// swallows the key before the menu). The host routes it to the window's shell action.
    func documentController(_ controller: DocumentController, requestsShellCommand name: String)
}

extension DocumentControllerDelegate {
    /// Optional: only the editor container reacts to it (test mocks opt out).
    func documentControllerDidSave(_ controller: DocumentController) {}
    func documentControllerDidRequestExplicitSave(_ controller: DocumentController) {}
    func documentController(_ controller: DocumentController, didFinishExplicitSave succeeded: Bool) {}
    func documentController(_ controller: DocumentController,
                            hasSaveConflictAt url: URL, backupAt backupURL: URL?) {}
    func documentController(_ controller: DocumentController, didFailSaveTo url: URL) {}
    func documentController(_ controller: DocumentController, didFailToOpen url: URL) {}
    func documentController(_ controller: DocumentController, requestsShellCommand name: String) {}
}

/// Drives one editor surface from one open `ChalkDocument`: opens the file and
/// seeds the editor, buffers edits in memory, and flushes them on demand.
final class DocumentController: NSObject, EditorSurfaceDelegate {
    weak var delegate: DocumentControllerDelegate?

    private let surface: EditorSurface
    private var document: ChalkDocument? {
        didSet { inheritedSearchDirs = nil }
    }
    /// `\graphicspath` inherited from a root file that `\input`s this one, cached per document because
    /// resolve-asset runs once per figure. An edit to the root file while this one stays open is missed.
    private var inheritedSearchDirs: (documentURL: URL, dirs: [URL])?
    private var buffer = DocumentBuffer(initial: "")
    /// Which file the buffer's text came from (nil for a draft). `save()` refuses to write a buffer whose
    /// provenance doesn't match `document`, so no path can write one file's text over another's.
    private var bufferSourceURL: URL?
    /// A draft has no backing file until the first save binds one; its content
    /// lives solely in `buffer`.
    private(set) var isDraft = false
    /// Stored here (not read off `document`) so a draft can seed the editor without a file.
    private(set) var language: EditorLanguage = .md
    /// The language the live surface was last initialized with. CM6 only switches tex/md mode on a fresh
    /// `init`, so tab reuse must re-init (not just `update`) when this differs from `language`. nil until
    /// seeded or after a web-process reset.
    private var seededLanguage: EditorLanguage?
    /// Security-scoped URL claimed by `bindDraft` (save destination outside the sandbox); released in `close()`.
    private var scopedURL: URL?
    private var isReady = false
    /// The contents have been read. `document` alone is not enough: it is assigned before the async read
    /// finishes, and seeding in that window would initialize the editor empty.
    private var isLoaded = false
    /// Reset when the web process dies so the fresh editor is seeded again.
    private var hasSeeded = false
    /// On-disk modification date as of our last read/write, for external-change detection.
    private var syncedModDate: Date?
    /// On-disk size at our last read/write, compared alongside the date: FAT/exFAT/SMB mtimes are whole
    /// seconds, so a fresher external write can carry the same date. A same-second, same-length write is
    /// still missed.
    private var syncedFileSize: Int?
    /// One document write at a time. Trailing save() callers queue here and are replayed as one coalesced
    /// save from the in-flight completion; overlapping writes (resign-active and didEnterBackground both run
    /// saveAll) would read our own fresh mtime as an external conflict.
    private var saveInFlight = false
    /// One external reload at a time. The file watcher and a focus pass can both fire on one write; a
    /// second read started before the first lands would push the same text twice. A check that arrives
    /// mid-read or mid-save sets `reloadPending` and reruns when that one lands.
    private var reloadInFlight = false
    private var reloadPending = false
    private var queuedSaveCompletions: [((Bool) -> Void)?] = []
    /// Watches `document` for a gained conflict version (iCloud picked a winner; the loser is invisible in
    /// the version store). Re-armed for every new `document`, removed in `close()`.
    private var documentStateObserver: NSObjectProtocol?
    /// The document `documentStateObserver` watches.
    private weak var conflictWatchedDocument: ChalkDocument?
    /// Live watch on the open file, so writes from other processes (an AI agent, another editor) reach
    /// `reloadIfChangedExternally` while the window stays up. Re-armed per file, cancelled in `close()`.
    private var fileWatcher: FileWatcher?
    /// Crash-recovered text that arrived while an open() was in flight; applied in its success completion.
    private var deferredRecoveredText: String?
    /// Crash-recovered text handed to `open(url:recoveredText:)` not yet applied. Survives a failed open so
    /// Retry can still apply it; cleared once applied or when the controller moves to another file.
    private var unappliedRecoveredText: String?
    /// The file the last `open`/`reopen` targeted. Survives a failed open (unlike `document`), so `reopen` can
    /// tell Retry (same file: keep parked recovery) from a browse elsewhere (drop it).
    private var loadTargetURL: URL?

    /// Crash-recovered text is parked but not yet applied. The container must not clear this tab's recovery
    /// snapshot while set: that record is the only copy of the crash edits.
    var hasUnappliedRecovery: Bool {
        unappliedRecoveredText != nil || deferredRecoveredText != nil
    }

    /// Whether the iCloud-conflict watch is on the current document (tests).
    var watchesConflictsOfCurrentDocumentForTesting: Bool {
        document != nil && conflictWatchedDocument === document
    }

    init(surface: EditorSurface) {
        self.surface = surface
        super.init()
        surface.delegate = self
    }

    var isDirty: Bool { buffer.isDirty }

    /// The buffer's live text (for the host to write out when saving a draft).
    var currentText: String { buffer.currentText }

    /// Open as an in-memory draft; the first save asks the delegate for a destination. `recoveredText`
    /// pre-fills the buffer as an unsaved edit. `language` is the draft's mode before a file exists.
    func openDraft(language: EditorLanguage = .md, recoveredText: String = "") {
        isDraft = true
        self.language = language
        buffer = DocumentBuffer(initial: "")
        bufferSourceURL = nil // a draft has no file yet
        loadTargetURL = nil
        if !recoveredText.isEmpty {
            // A pending edit: the draft opens dirty and the seed shows it.
            buffer.recordEdit(recoveredText)
        }
        isLoaded = true
        seedEditorIfPossible()
        delegate?.documentController(self, didChangeDirty: buffer.isDirty)
    }

    /// Open `url`, then seed the editor once both the document has loaded and the
    /// editor has signalled `ready`. `recoveredText` (crash recovery) is layered
    /// on top of the disk content as a pending unsaved edit.
    func open(url: URL, recoveredText: String? = nil) {
        isDraft = false
        deferredRecoveredText = nil // parked text belongs to a previous open
        unappliedRecoveredText = recoveredText // survives a failed open (C-2)
        loadTargetURL = url
        fileWatcher?.cancel() // re-armed by adoptLoaded once the new file is read
        let doc = ChalkDocument(fileURL: url)
        document = doc
        language = doc.language
        doc.open { [weak self] success in
            guard let self else { return }
            guard success else {
                log.error("failed to open \(url.lastPathComponent, privacy: .private)")
                if self.document === doc {
                    // A document that never loaded must not stay a write target: `didEdit` plus any
                    // save would write the buffer over whatever is at `url` (for a Quarto folder
                    // named `*.md`, replacing the whole folder). A nil `document` makes save() a no-op.
                    self.document = nil
                    self.isLoaded = false
                    self.delegate?.documentController(self, didFailToOpen: url)
                }
                return
            }
            // A slow open can finish after a later open/reopen swapped `document`: drop its stale text.
            guard self.document === doc else { return }
            self.adoptLoaded(doc)
            self.seedEditorIfPossible()
            self.delegate?.documentController(self, didChangeDirty: self.buffer.isDirty)
        }
    }

    /// The success path `open` and `reopen` share: the disk text becomes the buffer's baseline, any
    /// parked crash text layers on top, and the file is watched. The caller then seeds or pushes.
    private func adoptLoaded(_ doc: ChalkDocument) {
        buffer = DocumentBuffer(initial: doc.text)
        bufferSourceURL = doc.fileURL
        if let recovered = unappliedRecoveredText {
            unappliedRecoveredText = nil
            // Recovered edits layer on the disk baseline as a pending edit (tab opens dirty).
            // A snapshot equal to disk is stale (the save completed) and skipped.
            if recovered != doc.text { buffer.recordEdit(recovered) }
        }
        // Recovery drain raced this async open (see layerRecoveredText); same stale-snapshot rule.
        if let deferred = deferredRecoveredText {
            deferredRecoveredText = nil
            if deferred != doc.text { buffer.recordEdit(deferred) }
        }
        recordSyncedFileState(of: doc.fileURL)
        observeConflictState(of: doc)
        watchFile(at: doc.fileURL)
        isLoaded = true
    }

    private func watchFile(at url: URL) {
        fileWatcher?.cancel()
        fileWatcher = FileWatcher(url: url) { [weak self] in self?.reloadIfChangedExternally() }
    }

    /// Layer crash-recovered text onto an open (or still-opening) document as a pending unsaved edit: the
    /// recovery drain's path when session restore already reopened the file clean. Parked if the read is
    /// still in flight.
    func layerRecoveredText(_ text: String) {
        guard isLoaded else {
            deferredRecoveredText = text
            return
        }
        guard text != buffer.currentText else { return }
        buffer.recordEdit(text)
        pushText(text, language: language)
        delegate?.documentController(self, didChangeDirty: buffer.isDirty)
    }

    /// Re-read the file if it changed on disk and push it as a minimal diff (keeps the cursor). Called on
    /// foreground, on the file watcher and after cross-window saves. Unsaved local edits are merged with
    /// the disk change (`TextMerge`); when they clash, the local copy is kept and save()'s conflict copy
    /// takes over.
    func reloadIfChangedExternally() {
        // Mid-open, `syncedModDate` still describes the previous file.
        guard let doc = document, isLoaded else { return }
        // Our own write in flight looks external until its completion records the new (date, size), and
        // a read in flight hasn't recorded its own yet: both re-check once they land.
        guard !saveInFlight, !reloadInFlight else { reloadPending = true; return }
        // An undownloaded iCloud placeholder has no local bytes; a later foreground pass retries.
        if let values = try? doc.fileURL.resourceValues(
            forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
            values.isUbiquitousItem == true,
            values.ubiquitousItemDownloadingStatus == .notDownloaded {
            return
        }
        let onDiskState = Self.fileState(of: doc.fileURL)
        guard let onDisk = onDiskState.modDate else { return }
        // Any (date, size) difference counts, not just a newer date: coarse-mtime filesystems can give a
        // fresher external write the same date, and missing it means the next save clobbers it.
        guard let synced = syncedModDate,
              onDisk != synced || onDiskState.size != syncedFileSize else { return }
        // The merge inputs, captured here and checked again on landing: an edit typed during the read
        // means merging again, not dropping the disk change.
        let base = buffer.savedText
        let mine = buffer.currentText
        let hasLocalEdits = buffer.isDirty
        // Coordinated read, so a torn write from another process never becomes the document and the new
        // baseline; the mod date is read inside the same block so `syncedModDate` matches the content.
        // Strict UTF-8 like ChalkDocument: bail rather than adopt a lossy decode.
        //
        // `filePresenter: doc` is load-bearing: the open document is a presenter of this file, and a
        // nil-presenter coordinator would wait on notifying it while its queue may be busy.
        // Coordinating on its behalf skips self-notification but still serializes against other processes.
        //
        // Off the main thread: the read can block for seconds behind other writers (iCloud mid-sync).
        reloadInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var newText: String?
            var coordinatedDate: Date?
            var coordinatedSize: Int?
            var coordError: NSError?
            NSFileCoordinator(filePresenter: doc).coordinate(
                readingItemAt: doc.fileURL, options: [], error: &coordError
            ) { url in
                guard let data = try? Data(contentsOf: url) else { return }
                newText = String(data: data, encoding: .utf8)
                coordinatedSize = data.count
                // A stat, not `resourceValues`: off the main thread a URL's cached values are never
                // flushed, so an earlier reader of the same URL (the conflict check) leaves a stale date.
                coordinatedDate = Self.fileState(of: url).modDate
            }
            let merged = newText.flatMap { theirs in
                hasLocalEdits ? TextMerge.threeWay(base: base, mine: mine, theirs: theirs) : theirs
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.reloadInFlight = false
                defer {
                    if self.reloadPending {
                        self.reloadPending = false
                        self.reloadIfChangedExternally()
                    }
                }
                guard self.document === doc else { return }
                guard self.buffer.currentText == mine else {
                    self.reloadPending = true
                    return
                }
                guard coordError == nil, let text = newText else {
                    log.notice("external reload skipped for \(doc.fileURL.lastPathComponent, privacy: .private) (unreadable or not UTF-8)")
                    return
                }
                guard let merged else {
                    log.notice("\(doc.fileURL.lastPathComponent, privacy: .private) changed on disk where it has local edits; keeping local copy")
                    return
                }
                self.syncedModDate = coordinatedDate ?? onDisk
                self.syncedFileSize = coordinatedSize ?? onDiskState.size
                doc.text = text
                if merged == text {
                    self.buffer.adoptExternal(text)
                } else {
                    self.buffer.rebase(onto: text, pending: merged)
                }
                // pushText, not `surface.update`: a web process killed in the background and not yet
                // re-seeded would drop an `update`.
                if merged != mine { self.pushText(merged, language: self.language) }
                if self.buffer.isDirty != hasLocalEdits {
                    self.delegate?.documentController(self, didChangeDirty: self.buffer.isDirty)
                }
                log.info("\(hasLocalEdits ? "merged" : "reloaded") external change for \(doc.fileURL.lastPathComponent, privacy: .private)")
            }
        }
    }

    /// Date and size from one stat, so they can't straddle a write.
    private static func fileState(of url: URL) -> (modDate: Date?, size: Int?) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date,
                (attrs?[.size] as? NSNumber)?.intValue)
    }

    /// Record the on-disk (date, size) baseline after a read or write. This stats after the operation, so
    /// an external write in between is adopted as ours; save()'s conflict copy-aside is the safety floor.
    private func recordSyncedFileState(of url: URL) {
        let state = Self.fileState(of: url)
        syncedModDate = state.modDate
        syncedFileSize = state.size
    }

    /// Flush buffered edits to disk; no-op when clean. A draft asks the delegate for a destination even
    /// when untouched (Cmd+S on an empty draft opens the panel). `explicit` marks a user Cmd+S, which pins
    /// the tab even when nothing is written; automatic flushes leave it false.
    func save(explicit: Bool = false, completion: ((Bool) -> Void)? = nil) {
        // Before every early return: a no-op save is exactly the case this exists for.
        if explicit { delegate?.documentControllerDidRequestExplicitSave(self) }
        var completion = completion
        if explicit, !isDraft {
            let caller = completion
            completion = { [weak self] ok in
                caller?(ok)
                guard let self else { return }
                self.delegate?.documentController(self, didFinishExplicitSave: ok)
            }
        }
        if isDraft {
            guard let delegate else { completion?(false); return }
            delegate.documentController(self, needsSaveDestination: { ok in completion?(ok) })
            return
        }
        guard let doc = document, let text = buffer.textToFlush() else {
            completion?(true)
            return
        }
        // Provenance guard: refuse to write a buffer that did not come from this document (e.g. a reopen
        // whose read failed leaves `document` = the new file, `buffer` = the old one). The "never browse a
        // dirty tab" rule lives in EditorContainerViewController; this fails closed at the write itself.
        // After the no-op return above, so a clean mismatched tab doesn't report a failed save.
        if let source = bufferSourceURL, source != doc.fileURL {
            log.error("refusing to save: buffer came from a different file than the open document")
            delegate?.documentController(self, didFailSaveTo: doc.fileURL)
            completion?(false)
            return
        }
        // Serialize writes (see `saveInFlight`).
        if saveInFlight {
            queuedSaveCompletions.append(completion)
            return
        }
        saveInFlight = true
        // Conflict gate: the file changed under us since our last read/write (same (date, size) predicate as
        // reloadIfChangedExternally). Copy the disk version aside FIRST, then write anyway ("Keep Mine" is
        // the default); the copy is the safety floor, the alert only informs.
        let onDiskState = Self.fileState(of: doc.fileURL)
        if let synced = syncedModDate, let onDisk = onDiskState.modDate,
           onDisk != synced || onDiskState.size != syncedFileSize {
            let backup = Self.makeConflictBackup(of: doc.fileURL)
            delegate?.documentController(self, hasSaveConflictAt: doc.fileURL, backupAt: backup)
        }
        doc.text = text
        doc.save { [weak self] ok in
            guard let self else { return }
            self.saveInFlight = false
            let queued = self.queuedSaveCompletions
            self.queuedSaveCompletions = []
            // Then replay one coalesced save for callers that queued mid-write (clean → completes at once).
            let finish: (Bool) -> Void = { result in
                completion?(result)
                if !queued.isEmpty {
                    self.save { replayOK in queued.forEach { $0?(replayOK) } }
                }
            }
            // A rename/rebind landed mid-write: the write went to the OLD path. Report failure so the buffer
            // stays dirty and the next save targets the current path.
            guard self.document === doc else {
                finish(false)
                return
            }
            if ok {
                self.buffer.confirmFlush(text)
                self.recordSyncedFileState(of: doc.fileURL)
                // A disk change seen mid-write waited for this baseline (see reloadIfChangedExternally).
                if self.reloadPending {
                    self.reloadPending = false
                    self.reloadIfChangedExternally()
                }
                // Only on a confirmed write of real changes: see `documentControllerDidSave`.
                self.delegate?.documentControllerDidSave(self)
                self.delegate?.documentController(self, didChangeDirty: self.buffer.isDirty)
                // Cross-window sync (EditorContainer skips the posting controller).
                NotificationCenter.default.post(
                    name: .chalkDocumentDidSave, object: self,
                    userInfo: [ChalkNotificationKey.url: doc.fileURL])
            } else {
                log.error("save failed for \(doc.fileURL.lastPathComponent, privacy: .private) (buffer kept for retry)")
                self.delegate?.documentController(self, didFailSaveTo: doc.fileURL)
            }
            finish(ok)
        }
    }

    /// Copy the disk version of `fileURL` aside before a conflicting overwrite: the `<name>.conflict.<ext>`
    /// sibling first, else `RecoveryStore.conflictCopiesDirectory` (a per-file sandbox scope doesn't cover
    /// the folder). Returns the copy, or nil when both failed. `sourceURL` overrides what is copied (an
    /// iCloud loser version). Never replaces an earlier copy.
    private static func makeConflictBackup(of fileURL: URL, copying sourceURL: URL? = nil) -> URL? {
        let src = sourceURL ?? fileURL
        let fm = FileManager.default
        do {
            let sibling = conflictCopyURL(for: fileURL, in: fileURL.deletingLastPathComponent())
            try fm.copyItem(at: src, to: sibling)
            return sibling
        } catch {
            do {
                let dir = RecoveryStore.conflictCopiesDirectory
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = conflictCopyURL(for: fileURL, in: dir)
                try fm.copyItem(at: src, to: dest)
                return dest
            } catch {
                log.error("conflict copy-aside failed for \(fileURL.lastPathComponent, privacy: .private): \(DiagError(error), privacy: .public)")
                return nil
            }
        }
    }

    /// The first free `<name>.conflict.<ext>` in `directory` (`<name> 2.conflict.<ext>`, …).
    private static func conflictCopyURL(for fileURL: URL, in directory: URL) -> URL {
        let ext = fileURL.pathExtension
        let name = FileNaming.uniqueName(
            base: fileURL.deletingPathExtension().lastPathComponent,
            ext: ext.isEmpty ? "conflict" : "conflict.\(ext)",
            isTaken: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) })
        return directory.appendingPathComponent(name)
    }

    func close() {
        if let documentStateObserver {
            NotificationCenter.default.removeObserver(documentStateObserver)
            self.documentStateObserver = nil
        }
        fileWatcher?.cancel()
        fileWatcher = nil
        document?.close()
        document = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    deinit {
        // Block-based observers are not auto-removed, and a tab can be released without `close()`.
        if let documentStateObserver {
            NotificationCenter.default.removeObserver(documentStateObserver)
        }
    }

    /// Arm the iCloud-conflict watch. The notification is per-document, and a conflict can already
    /// exist before the observer registers, hence the immediate check.
    private func observeConflictState(of doc: ChalkDocument) {
        if let documentStateObserver {
            NotificationCenter.default.removeObserver(documentStateObserver)
        }
        conflictWatchedDocument = doc
        documentStateObserver = NotificationCenter.default.addObserver(
            forName: ChalkDocument.stateChangedNotification, object: doc, queue: .main
        ) { [weak self] _ in
            self?.resolveConflictVersionsIfNeeded()
        }
        resolveConflictVersionsIfNeeded()
    }

    /// Serial, so a second notification queries only after the first run discarded what it copied.
    private static let conflictQueue = DispatchQueue(label: "com.huleux.chalk.conflict-versions", qos: .utility)

    /// iCloud resolved a conflict by last-writer-wins; the losers sit invisible in the version store. Copy
    /// each aside, tell the host, and discard the copied ones. The query and the copies run off-main:
    /// both can block on the ubiquity store.
    private func resolveConflictVersionsIfNeeded() {
        guard let doc = document else { return }
        let url = doc.fileURL
        Self.conflictQueue.async { [weak self] in
            guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
                  !versions.isEmpty else { return }
            let backup = Self.settleConflictVersions(versions) {
                Self.makeConflictBackup(of: url, copying: $0)
            }
            // Nothing copied means nothing discarded: every loser is still in conflict.
            guard let backup else {
                log.error("no iCloud conflict version of \(url.lastPathComponent, privacy: .private) could be copied aside; left in conflict")
                return
            }
            DispatchQueue.main.async {
                guard let self, self.document === doc else { return }
                self.delegate?.documentController(self, hasSaveConflictAt: url, backupAt: backup)
            }
        }
    }

    /// Copy every losing version aside, newest first, and discard only those whose copy landed, so a
    /// failed one stays in the version store for a later pass. Returns the newest copy, or nil.
    static func settleConflictVersions<Version: ConflictVersion>(
        _ versions: [Version], backup: (URL) -> URL?
    ) -> URL? {
        let newestFirst = versions.sorted {
            ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast)
        }
        var newestBackup: URL?
        for version in newestFirst {
            guard let copy = backup(version.url) else { continue }
            if newestBackup == nil { newestBackup = copy }
            do {
                try version.discard()
            } catch {
                log.error("could not discard a copied iCloud conflict version: \(DiagError(error), privacy: .public)")
            }
        }
        return newestBackup
    }

    /// Rebind to a file already moved/renamed on disk, WITHOUT reloading, so unsaved edits in `buffer`
    /// survive and the next save writes to `newURL`. Dirty state lives in `buffer`, never in the document,
    /// so closing the old handle never rewrites the vacated path. A rename that flips
    /// `.md`/`.tex` re-inits the surface from the live buffer, resetting CM6 undo history.
    func rebind(to newURL: URL) {
        document?.close()
        let doc = ChalkDocument(fileURL: newURL)
        document = doc
        // Never opened, but the next save registers it as a presenter, and then it can go into conflict.
        observeConflictState(of: doc)
        watchFile(at: newURL)
        // A rename carries the buffer to the new path on purpose: the one legitimate provenance change
        // without a read.
        bufferSourceURL = newURL
        loadTargetURL = newURL
        language = EditorLanguage(fileExtension: newURL.pathExtension)
        recordSyncedFileState(of: newURL)
        if language != seededLanguage {
            reinitializeSurface(text: buffer.currentText, language: language)
        }
    }

    /// Bind a draft to the file the user just saved it to. The save panel already put the content at
    /// `url`, so this is metadata-only. Claims security-scoped access for destinations outside the sandbox.
    func bindDraft(to url: URL, writtenText: String) {
        guard isDraft else { return }
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        let doc = ChalkDocument(fileURL: url)
        doc.text = writtenText
        document = doc
        observeConflictState(of: doc) // see rebind
        watchFile(at: url)
        language = doc.language
        isDraft = false
        // An edit typed while the panel was up stays pending, so the tab stays dirty.
        buffer.confirmFlush(writtenText)
        bufferSourceURL = url
        loadTargetURL = url
        recordSyncedFileState(of: url)
        // The save panel can change the extension: switch mode like a cross-language rename.
        if language != seededLanguage {
            reinitializeSurface(text: buffer.currentText, language: language)
        }
        delegate?.documentController(self, didChangeDirty: buffer.isDirty)
    }

    /// Reopen this controller on a DIFFERENT file, reusing the live surface (tab browse-reuse). Same
    /// language: push through the minimal-diff `update`. Crossing `.md`/`.tex`: re-init, since CM6 picks its
    /// language only at `init`. Callers only reuse a clean tab, so discarding the buffer loses no edits.
    func reopen(url: URL) {
        isDraft = false // browse-reuse can consume a clean draft tab
        // Parked crash text must survive a reopen of the SAME file (the failure alert's Retry lands here);
        // for any other target it belongs to the previous file. `document` is nil after a failed open, so
        // compare against the load target.
        if loadTargetURL != url {
            deferredRecoveredText = nil
            unappliedRecoveredText = nil
        }
        loadTargetURL = url
        // Until the async read completes the buffer holds the PREVIOUS file: stop a mid-reopen `ready` from
        // seeding it.
        isLoaded = false
        fileWatcher?.cancel() // re-armed by adoptLoaded once the new file is read
        document?.close()
        let doc = ChalkDocument(fileURL: url)
        document = doc
        language = doc.language
        doc.open { [weak self] success in
            guard let self else { return }
            // Rapid browse-clicks race their opens: only the load for the current `document` wins.
            guard self.document === doc else { return }
            guard success else {
                log.error("failed to reopen \(url.lastPathComponent, privacy: .private)")
                self.delegate?.documentController(self, didFailToOpen: url)
                return
            }
            self.adoptLoaded(doc)
            self.pushText(self.buffer.currentText, language: doc.language)
            self.delegate?.documentController(self, didChangeDirty: self.buffer.isDirty)
        }
    }

    private func seedEditorIfPossible() {
        guard isReady, isLoaded, !hasSeeded else {
            log.info("seed gate: ready=\(self.isReady) loaded=\(self.isLoaded) seeded=\(self.hasSeeded)")
            return
        }
        hasSeeded = true
        log.info("seeding editor (\(self.buffer.currentText.count) chars)")
        // The buffer, not doc.text: after a web-process crash it may hold unsaved edits.
        reinitializeSurface(text: buffer.currentText, language: language)
    }

    /// Hsnips sent to each fresh page: bundled defaults plus the user's Settings shortcuts. Injectable for
    /// tests.
    var hsnipsProvider: () -> String? = { SnippetLibrary.shared.composedContent() }

    /// The window's Library Locations, bounding the figure search above the document's directory. Set by
    /// the window's EditorContainerViewController; injectable for tests.
    var libraryRootsProvider: () -> [URL] = { [] }

    /// Send a fresh `init`, rebuilding the CM6 view in `language` mode. No editor config or hsnips: the
    /// surface sends config on `ready`, and the page keeps both across re-inits.
    private func reinitializeSurface(text: String, language: EditorLanguage) {
        surface.initialize(text: text, language: language, editorConfig: nil)
        seededLanguage = language
        // Every init path funnels through here, so `hasSeeded` is the one signal that a bare `update` is
        // safe (the surface's queue keeps FIFO order behind this init).
        hasSeeded = true
    }

    /// Send `init` unless this editor generation is seeded in the same language, else a minimal-diff
    /// `update`. An `update` to a viewless editor is silently dropped (a permanently empty tab), and CM6
    /// only switches tex/md mode on `init`.
    private func pushText(_ text: String, language: EditorLanguage) {
        if !hasSeeded || language != seededLanguage {
            reinitializeSurface(text: text, language: language)
        } else {
            surface.update(text: text)
        }
    }

    // MARK: EditorSurfaceDelegate

    func editorDidBecomeReady(_ surface: EditorSurface) {
        isReady = true
        // Once per page, before the seed: a fresh page has no snippets and keeps these across inits.
        // Asked each time so a crash reload picks up Settings edits.
        if let hsnips = hsnipsProvider() {
            surface.setHsnips(content: hsnips)
        }
        seedEditorIfPossible()
    }

    func editorDidResetConnection(_ surface: EditorSurface) {
        isReady = false
        hasSeeded = false // the reloaded editor needs a fresh seed on `ready`
        seededLanguage = nil // the torn-down view has no language until re-seeded
    }

    func editor(_ surface: EditorSurface, didEdit text: String) {
        // save() writes the buffer, so it only accepts text for a loaded document; otherwise a failed or
        // mid-reopen controller is a write target aimed at the wrong path. Drafts set isLoaded.
        guard isLoaded else { return }
        let wasDirty = buffer.isDirty
        buffer.recordEdit(text)
        if buffer.isDirty != wasDirty {
            delegate?.documentController(self, didChangeDirty: buffer.isDirty)
        }
    }

    func editor(_ surface: EditorSurface, requestsOpenExternal url: URL) {
        // Content-driven URLs: allowlist the schemes (mirrors the VS Code host's SAFE_EXTERNAL_SCHEMES).
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else {
            log.notice("open-external rejected scheme: \(url.absoluteString, privacy: .private)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func editor(_ surface: EditorSurface, resolveAsset src: String) async -> String? {
        // Called off-main while `document`/`language`/`buffer` mutate on main: snapshot on the main actor,
        // then do file IO here.
        let snapshot = await MainActor.run {
            () -> (url: URL, directory: URL, texSource: String?, workspaceRoot: URL?, cached: [URL]?)? in
            guard let doc = document else { return nil } // drafts have no directory
            let directory = doc.fileURL.deletingLastPathComponent()
            return (doc.fileURL,
                    directory,
                    language == .tex ? buffer.currentText : nil,
                    AssetResolution.workspaceRoot(for: directory, roots: libraryRootsProvider()),
                    inheritedSearchDirs.flatMap { $0.documentURL == doc.fileURL ? $0.dirs : nil })
        }
        guard let snapshot else { return nil }

        // An `\input`-ed subfile has no preamble: scan neighbouring `.tex` files for the root's
        // `\graphicspath` once per document, then cache unless the document moved on meanwhile.
        var inherited: [URL] = []
        if snapshot.texSource != nil {
            if let cached = snapshot.cached {
                inherited = cached
            } else {
                inherited = Self.inheritedGraphicsDirs(
                    document: snapshot.url,
                    directory: snapshot.directory,
                    workspaceRoot: snapshot.workspaceRoot)
                let dirs = inherited
                await MainActor.run {
                    guard document?.fileURL == snapshot.url else { return }
                    inheritedSearchDirs = (snapshot.url, dirs)
                }
            }
        }

        // Failed reads (including siblings of a Files-app file, scoped to itself) resolve nil and show the
        // missing-image placeholder.
        let graphicsPaths = snapshot.texSource.map(AssetResolution.graphicsPaths(inTeX:)) ?? []
        guard let resolved = AssetResolution.resolveAsset(
            src: src,
            documentDirectory: snapshot.directory,
            graphicsPaths: graphicsPaths,
            allowExtensionProbing: snapshot.texSource != nil,
            // TeX only: markdown srcs are literal, and a same-named file higher up must not stand in.
            workspaceRoot: snapshot.texSource != nil ? snapshot.workspaceRoot : nil,
            extraSearchDirs: inherited,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        ) else { return nil }
        return AssetLoader.loadDataURL(url: resolved.url, kind: resolved.kind)
    }

    /// Caps on the root-file scan, so a directory of generated `.tex` can't turn one figure into a disk sweep.
    private static let maxRootScanFilesPerDirectory = 12
    private static let maxRootScanBytes = 512 * 1024

    /// `\graphicspath` directories declared by the OTHER `.tex` files beside and above this document (up to
    /// the Library root), nearest first: how an `\input`-ed section inherits the root's figure directory.
    private static func inheritedGraphicsDirs(
        document: URL,
        directory: URL,
        workspaceRoot: URL?
    ) -> [URL] {
        let documentPath = document.standardizedFileURL.path
        var sources: [(url: URL, source: String)] = []
        for dir in [directory] + AssetResolution.ancestorDirectories(of: directory, upTo: workspaceRoot) {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles])) ?? []
            let texFiles = entries
                .filter { $0.pathExtension.lowercased() == "tex" }
                .filter { $0.standardizedFileURL.path != documentPath }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .prefix(maxRootScanFilesPerDirectory)
            for url in texFiles {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey])).flatMap(\.fileSize)
                guard let size, size <= maxRootScanBytes,
                      let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                sources.append((url, source))
            }
        }
        return AssetResolution.graphicsSearchDirs(declaredIn: sources)
    }

    /// Document-directory files for completions. Same main-actor snapshot as `resolveAsset`. A Files-app file
    /// is scoped to itself, so the walk finds nothing there.
    func editor(_ surface: EditorSurface, listFiles kinds: [WorkspaceFileKind]) async -> [String] {
        guard !kinds.isEmpty else { return [] }
        let directory = await MainActor.run { document?.fileURL.deletingLastPathComponent() }
        guard let directory else { return [] }
        return FileTree.relativePaths(in: directory, kinds: kinds)
    }

    /// Read a document-relative file as text, for `.bib` parsing.
    func editor(_ surface: EditorSurface, readText path: String) async -> String? {
        let directory = await MainActor.run { document?.fileURL.deletingLastPathComponent() }
        guard let directory else { return nil }

        // `path` comes from the web layer: keep `../` from reaching anywhere the sandbox allows.
        let base = directory.standardizedFileURL
        let target = base.appendingPathComponent(path).standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else {
            log.notice("read-text rejected path outside the document directory")
            return nil
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: target.path),
              let size = attrs[.size] as? Int, size <= Self.maxReadTextBytes else { return nil }
        return try? String(contentsOf: target, encoding: .utf8)
    }

    /// A bibliography this large is useless in the completion popup, and it crosses IPC.
    private static let maxReadTextBytes = 2 * 1024 * 1024

    /// pdflatex runs in the document's folder, so the picture's `\input`s resolve as in a compile.
    func editor(_ surface: EditorSurface, renderTikz document: String) async -> TikzRenderResult? {
        let directory = await MainActor.run { self.document?.fileURL.deletingLastPathComponent() }
        return await TikzRenderService.shared.render(.init(document: document, workingDirectory: directory))
    }

    func editor(_ surface: EditorSurface, requestsCommand name: String) {
        // Raw value of ChalkKit's `ShellCommand`; unknown names go to the shell, which ignores them.
        if ShellCommand(rawValue: name) == .save {
            // A focused webview swallows Cmd+S before the menu, so this IS an explicit save.
            save(explicit: true)
        } else {
            delegate?.documentController(self, requestsShellCommand: name)
        }
    }
}

/// One losing version of an iCloud conflict. A protocol so the settle rule is testable: the ubiquity
/// store cannot fabricate a conflict.
protocol ConflictVersion {
    var url: URL { get }
    var modificationDate: Date? { get }
    /// Mark the version resolved and remove it from the version store.
    func discard() throws
}

extension NSFileVersion: ConflictVersion {
    func discard() throws {
        isResolved = true
        try remove()
    }
}
