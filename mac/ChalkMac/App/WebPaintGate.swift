import AppKit
import ChalkKit

/// The covered-reflow settle of docs/motion.md, shared by the transitions that
/// reflow or restyle the webview (the sidebar slide, the appearance flip).
///
/// The sequence: opaque cover (the old pixels if a snapshot arrived in time,
/// else the plain surface colour) -> the one reflow, stationary, under the
/// cover -> cover fade once the page has committed a paint of the new layout.
/// The release is armed as a `DispatchWorkItem` before any async step, and the
/// snapshot callback, the paint gate and both backstops funnel into the same
/// two idempotent steps (`finish`, then `dismiss`), so a dead snapshotter or a
/// stalled web process degrades to a covered reflow on the backstop clock,
/// never a stuck width or a naked reflow.
///
/// Main-thread only, by convention rather than `@MainActor`, like the rest of
/// the shell.
final class WebPaintGate {
    /// Asks for a bitmap of the CURRENT (pre-reflow) pixels. Answering with
    /// nil, answering late, or never answering are all survivable; a late
    /// answer is discarded.
    typealias Snapshotter = (@escaping (NSImage?) -> Void) -> Void
    /// Runs the completion once the page has committed a paint of the
    /// post-reflow layout (two in-page rAFs). Never running it is survivable.
    typealias PaintGate = (@escaping () -> Void) -> Void

    struct Timing {
        /// How long a missing snapshot may delay the release.
        var snapshotBackstop: TimeInterval = 0.25
        /// How long a stalled repaint may hold the cover after the reflow.
        var paintBackstop: TimeInterval = 0.6
        /// The cover fade (docs/motion.md: cover fades ride `motionFast`).
        var fade: TimeInterval = ChalkMetrics.motionFast
    }

    private let snapshotter: Snapshotter
    private let paintGate: PaintGate
    /// Builds AND installs the cover for the given bitmap (nil: plain
    /// opaque), returning it so this gate can fade and remove it. Runs
    /// exactly once, before the reflow, so it sees pre-reflow geometry.
    private let makeCover: (NSImage?) -> NSView?
    /// The one real reflow. Runs exactly once, right after the cover is up.
    private let reflow: () -> Void
    private let timing: Timing

    private var cover: NSView?
    private var finished = false
    private var dismissed = false
    private var snapshotBackstopWork: DispatchWorkItem?
    private var paintBackstopWork: DispatchWorkItem?

    /// True from `begin()` until the cover is gone (or `cancel()`); the
    /// transition seam reports it so tests can pin "nothing still owns state".
    private(set) var isActive = false

    init(snapshotter: @escaping Snapshotter,
         paintGate: @escaping PaintGate,
         makeCover: @escaping (NSImage?) -> NSView?,
         reflow: @escaping () -> Void,
         timing: Timing = Timing()) {
        self.snapshotter = snapshotter
        self.paintGate = paintGate
        self.makeCover = makeCover
        self.reflow = reflow
        self.timing = timing
    }

    func begin() {
        isActive = true
        // The release is armed BEFORE the async snapshot ask (the contract's
        // guaranteed-release clause): a snapshotter that never answers costs
        // `snapshotBackstop` of frozen width, then the covered reflow runs
        // without the bitmap.
        let backstop = DispatchWorkItem { [weak self] in self?.finish(bitmap: nil) }
        snapshotBackstopWork = backstop
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.snapshotBackstop,
                                      execute: backstop)
        snapshotter { [weak self] image in self?.finish(bitmap: image) }
    }

    /// A canceled settle (rapid re-toggle) releases everything NOW and turns
    /// every pending callback into a no-op: a stale snapshot or backstop
    /// must never install a cover into the next slide.
    func cancel() {
        finished = true
        dismissed = true
        snapshotBackstopWork?.cancel()
        paintBackstopWork?.cancel()
        cover?.removeFromSuperview()
        cover = nil
        isActive = false
    }

    /// Cover up, reflow once, then wait for the paint, from the snapshot or
    /// from its backstop, whichever lands first; the loser is discarded.
    private func finish(bitmap: NSImage?) {
        guard !finished else { return }
        finished = true
        snapshotBackstopWork?.cancel()
        cover = makeCover(bitmap)
        reflow()
        let backstop = DispatchWorkItem { [weak self] in self?.dismiss() }
        paintBackstopWork = backstop
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.paintBackstop,
                                      execute: backstop)
        paintGate { [weak self] in self?.dismiss() }
    }

    private func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        paintBackstopWork?.cancel()
        guard let cover else {
            isActive = false
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = timing.fade
            cover.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            cover.removeFromSuperview()
            guard let self else { return }
            if self.cover === cover { self.cover = nil }
            self.isActive = false
        })
    }
}
