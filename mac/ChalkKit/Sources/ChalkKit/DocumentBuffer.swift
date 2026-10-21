import Foundation

/// Buffer-then-flush model for one open document: edits stay in memory until
/// an explicit save. No per-keystroke autosave.
public final class DocumentBuffer {
    /// The text last known to be on disk.
    public private(set) var savedText: String
    /// The latest edit not yet flushed (nil when nothing is pending).
    public private(set) var pendingText: String?

    public init(initial: String) {
        savedText = initial
    }

    /// What the editor currently shows (pending if any, else saved).
    public var currentText: String {
        pendingText ?? savedText
    }

    /// True when there are unsaved edits. Stored, not computed: it is read
    /// several times per keystroke, so the compare runs once per mutation.
    public private(set) var isDirty: Bool = false

    /// Record an editor edit. Buffered, not written.
    public func recordEdit(_ text: String) {
        pendingText = text
        isDirty = Self.differ(text, savedText)
    }

    /// `String ==` on non-ASCII text (any math document) is a normalising walk
    /// of the whole document per keystroke; the byte counts, O(1) on native
    /// strings, disagree after almost every edit.
    private static func differ(_ a: String, _ b: String) -> Bool {
        a.utf8.count != b.utf8.count || a != b
    }

    /// The text a flush should write, or nil if nothing needs saving.
    public func textToFlush() -> String? {
        isDirty ? currentText : nil
    }

    /// Mark `text` as written. A newer edit that arrived during the write stays
    /// pending.
    public func confirmFlush(_ text: String) {
        savedText = text
        if pendingText == text {
            pendingText = nil
        }
        isDirty = pendingText.map { Self.differ($0, savedText) } ?? false
    }

    /// Adopt an external change as the saved baseline, when no local edits are
    /// pending.
    public func adoptExternal(_ text: String) {
        savedText = text
        pendingText = nil
        isDirty = false
    }

    /// Adopt an external change as the saved baseline while keeping local edits,
    /// already merged into `pending` (`TextMerge.threeWay`).
    public func rebase(onto text: String, pending: String) {
        savedText = text
        pendingText = pending
        isDirty = Self.differ(pending, text)
    }
}
