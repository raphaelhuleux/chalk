import CryptoKit
import Foundation

/// A document's AI marks and the text they index. `text` is what lets a reopen see a file changed
/// while Chalk was closed: the seed shows it, then an `update` carries the document to the disk text.
public struct AiMarkRecord: Codable, Equatable, Sendable {
    public var path: String
    public var text: String
    public var marks: [AiMark]

    public init(path: String, text: String, marks: [AiMark]) {
        self.path = path
        self.text = text
        self.marks = marks
    }
}

/// One JSON file per marked document, keyed by `URL.fileIdentity`. A document with no marks has no
/// file, so the folder only ever holds what the user still has to review.
///
/// Writes go through one serial queue, coalesced to the latest record per path: typing in a marked
/// document moves its marks on every debounced push.
public final class ProvenanceStore: @unchecked Sendable {
    public static let shared = ProvenanceStore(directory: RecoveryStore.aiMarksDirectory)

    private let directory: URL
    private let queue = DispatchQueue(label: "com.huleux.chalk.ai-marks", qos: .utility)
    /// Only touched on `queue`. A nil value is a removal.
    private var unwritten: [String: AiMarkRecord?] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    /// Writes pending for this path win over the file, so a re-seed right after a push is current.
    public func load(path: String) -> AiMarkRecord? {
        queue.sync {
            if let pending = unwritten[path] { return pending }
            guard let data = try? Data(contentsOf: url(for: path)) else { return nil }
            return try? JSONDecoder().decode(AiMarkRecord.self, from: data)
        }
    }

    public func save(_ record: AiMarkRecord) {
        enqueue(record.path, record)
    }

    public func remove(path: String) {
        enqueue(path, nil)
    }

    /// A rename inside Chalk: the record follows the file.
    public func move(from oldPath: String, to newPath: String) {
        guard oldPath != newPath, var record = load(path: oldPath) else { return }
        record.path = newPath
        remove(path: oldPath)
        save(record)
    }

    /// Blocks until queued writes are on disk.
    public func flush() {
        queue.sync { writePending() }
    }

    private func enqueue(_ path: String, _ record: AiMarkRecord?) {
        queue.async {
            let idle = self.unwritten.isEmpty
            self.unwritten[path] = .some(record)
            if idle { self.queue.async { self.writePending() } }
        }
    }

    private func writePending() {
        let batch = unwritten
        unwritten = [:]
        for (path, record) in batch {
            let file = url(for: path)
            guard let record else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(record).write(to: file, options: .atomic)
        }
    }

    private func url(for path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }
}

/// Text this process just wrote, by file. Another window's save reaches a tab through its file
/// watcher, and that tab can't otherwise tell it from an outside write; a user's own text must not
/// come back marked. Main thread only.
public final class OwnSaves {
    public static let shared = OwnSaves()

    private static let keptPerFile = 8
    private var recent: [String: [Int]] = [:]

    public init() {}

    public func record(_ text: String, path: String) {
        var hashes = recent[path] ?? []
        hashes.append(text.hashValue)
        recent[path] = Array(hashes.suffix(Self.keptPerFile))
    }

    public func contains(_ text: String, path: String) -> Bool {
        recent[path]?.contains(text.hashValue) ?? false
    }
}
