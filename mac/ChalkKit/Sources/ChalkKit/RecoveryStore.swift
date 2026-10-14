import Foundation

/// One recovered buffer. `fileURL` is nil for a draft that never had a file.
/// `launchID` lets the drain tell crash residue from a live window's
/// snapshot; nil (an unstamped file) is treated as residue.
public struct RecoveryRecord: Equatable {
    public let id: String
    public let text: String
    public let fileURL: URL?
    public let savedAt: Date
    public let launchID: String?

    public init(id: String, text: String, fileURL: URL?, savedAt: Date,
                launchID: String? = nil) {
        self.id = id
        self.text = text
        self.fileURL = fileURL
        self.savedAt = savedAt
        self.launchID = launchID
    }
}

/// The crash net behind no-autosave: dirty buffers are periodically
/// snapshotted here (one JSON file per document id), cleared on save/clean
/// close, and offered back on the next launch. A graceful session leaves the
/// directory empty.
///
/// Not locked: callers serialize, via EditorContainerViewController's
/// `recoveryQueue`, so per-id write/clear order holds.
public final class RecoveryStore {
    private struct Entry: Codable {
        let id: String
        let text: String
        let filePath: String?
        let savedAt: Date
        let launchID: String? // absent in unstamped files
    }

    /// One id per process. The drain treats a matching record as live dirty
    /// state some window owns, which a mid-session scene connect must not
    /// "recover".
    public static let currentLaunchID = UUID().uuidString

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Persist (or replace) the snapshot for `id`, atomically so a torn write
    /// never corrupts a good snapshot.
    public func snapshot(id: String, text: String, fileURL: URL?,
                         launchID: String = RecoveryStore.currentLaunchID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = Entry(
            id: id, text: text, filePath: fileURL?.path, savedAt: Date(),
            launchID: launchID)
        let data = try JSONEncoder().encode(entry)
        try data.write(to: url(for: id), options: .atomic)
    }

    public func clear(id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    public func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// All recoverable snapshots, oldest first. Unreadable/corrupt entries are
    /// skipped — a half-written file must never block recovery of the others.
    public func pending() -> [RecoveryRecord] {
        snapshotFiles()
            .compactMap { file -> RecoveryRecord? in
                guard let entry = self.entry(at: file) else { return nil }
                return RecoveryRecord(
                    id: entry.id,
                    text: entry.text,
                    fileURL: entry.filePath.map { URL(fileURLWithPath: $0) },
                    savedAt: entry.savedAt,
                    launchID: entry.launchID)
            }
            .sorted { $0.savedAt < $1.savedAt }
    }

    // MARK: - Hygiene
    //
    // Backs the Privacy screen's disclosure and delete: must be cheap to ask
    // and safe to run mid-session.

    /// How many snapshots exist, without decoding any (`pending()` would read
    /// every unsaved document's text). Corrupt files count: they still occupy
    /// space and still need deleting.
    public func pendingCount() -> Int {
        snapshotFiles().count
    }

    /// Total bytes on disk, for the "Chalk is holding N documents (M KB)" row.
    public func usage() -> Int {
        snapshotFiles().reduce(0) { total, file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return total + (size ?? 0)
        }
    }

    /// When the earliest surviving snapshot was written, by file mtime so a
    /// corrupt entry still counts.
    public func oldestPendingDate() -> Date? {
        snapshotFiles().compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }.min()
    }

    /// Delete every snapshot except the ones this process wrote.
    ///
    /// UI calls this, never `clearAll()`, which would also delete the live
    /// windows' snapshots and silently disarm the crash net for the session.
    /// Unstamped and undecodable files are removed too, or nothing could
    /// ever clear them.
    ///
    /// - Returns: how many were removed.
    @discardableResult
    public func clearPreviousLaunches() -> Int {
        var removed = 0
        for file in snapshotFiles() {
            let launchID = entry(at: file)?.launchID
            guard launchID != RecoveryStore.currentLaunchID else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// Every `.json` in the directory. Never creates it: asking a question
    /// must not have a side effect.
    private func snapshotFiles() -> [URL] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return [] }
        return files.filter { $0.pathExtension == "json" }
    }

    private func entry(at file: URL) -> Entry? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func url(for id: String) -> URL {
        // Percent-encode so arbitrary ids (tab UUIDs today, maybe paths later)
        // can't escape the directory or collide.
        let safe = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return directory.appendingPathComponent("\(safe).json")
    }
}
