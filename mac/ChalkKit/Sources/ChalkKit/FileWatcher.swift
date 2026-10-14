import Foundation

/// Calls `onChange` (debounced, on `queue`) when the file at `url` is written, replaced or recreated by
/// any process. Writers that don't use NSFileCoordinator (editors, CLI agents) never reach a
/// presenter's `presentedItemDidChange`, so this watches the vnode instead.
///
/// The watch is on the inode, not the path: an atomic save (write a temp file, rename it over) leaves
/// the old inode orphaned, so `.delete`/`.rename` re-arms on whatever the path names now. Events are
/// a hint only; the owner re-checks the file itself.
public final class FileWatcher {
    private let url: URL
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pendingNotify: DispatchWorkItem?
    /// Re-arm retries while the path is missing (mid-replace, or deleted and recreated later).
    private var rearmAttempts = 0
    private static let maxRearmAttempts = 40
    private static let rearmInterval: TimeInterval = 0.25
    private var isCancelled = false

    /// Must be created, used and cancelled on `queue`.
    public init(url: URL, queue: DispatchQueue = .main, debounce: TimeInterval = 0.15,
                onChange: @escaping () -> Void) {
        self.url = url
        self.queue = queue
        self.debounce = debounce
        self.onChange = onChange
        arm()
    }

    deinit {
        source?.cancel()
        pendingNotify?.cancel()
    }

    public func cancel() {
        isCancelled = true
        source?.cancel()
        source = nil
        pendingNotify?.cancel()
        pendingNotify = nil
    }

    private func arm() {
        guard !isCancelled else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            guard rearmAttempts < Self.maxRearmAttempts else { return }
            rearmAttempts += 1
            queue.asyncAfter(deadline: .now() + Self.rearmInterval) { [weak self] in self?.arm() }
            return
        }
        // Armed after a gap: the path was recreated, so its content may be new.
        if rearmAttempts > 0 { scheduleNotify() }
        rearmAttempts = 0
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename], queue: queue)
        src.setEventHandler { [weak self, unowned src] in
            guard let self, !self.isCancelled else { return }
            if !src.data.isDisjoint(with: [.delete, .rename]) {
                src.cancel()
                self.source = nil
                self.arm()
            }
            self.scheduleNotify()
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    /// Coalesce a burst (truncate + write + chmod of one save) into one callback.
    private func scheduleNotify() {
        pendingNotify?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.onChange()
        }
        pendingNotify = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
