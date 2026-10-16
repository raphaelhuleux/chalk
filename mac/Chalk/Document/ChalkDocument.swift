import Foundation
import ChalkKit

/// A text file as a file presenter with coordinated reads and writes, without `NSDocument`'s window
/// and change-count machinery (plan decision 2). The in-memory text is the source of truth while
/// open; `DocumentController` decides when to write it.
///
/// Reads and writes run off the main thread and complete on it. `text` is read and written on the
/// main thread only.
final class ChalkDocument: NSObject, NSFilePresenter {
    let fileURL: URL

    /// The document's text. Set before calling `save` to flush an edit.
    var text: String = ""

    /// Editor language inferred from the file extension.
    var language: EditorLanguage {
        EditorLanguage(fileExtension: fileURL.pathExtension)
    }

    enum LoadError: Error, Equatable {
        /// Not valid UTF-8. Refuse rather than lossy-decode, or the next save writes U+FFFD back.
        case notUTF8
        /// A directory or package. Opening it as a blank document would let a save replace the
        /// folder with a flat file.
        case notAFile
    }

    /// Posted (object: the document, main queue) when the version store gains a conflict version
    /// for this file: the one state change `DocumentController` acts on.
    static let stateChangedNotification = Notification.Name("chalk.documentStateDidChange")

    /// Serial, as `NSFilePresenter` requires for the callbacks.
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.huleux.chalk.document.presenter"
        return queue
    }()

    var presentedItemURL: URL? { fileURL }

    private var isPresenting = false

    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init()
    }

    deinit {
        if isPresenting { NSFileCoordinator.removeFilePresenter(self) }
    }

    /// Register as the file's presenter, so coordinated writes by other processes notify us and our
    /// own coordinated operations skip self-notification. Idempotent.
    private func startPresenting() {
        guard !isPresenting else { return }
        isPresenting = true
        NSFileCoordinator.addFilePresenter(self)
    }

    // MARK: - Decoding

    /// The one gate between a file's bytes and the buffer a later save writes back.
    static func decode(_ data: Data) throws -> String {
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw LoadError.notUTF8
        }
        return decoded
    }

    // MARK: - Reading

    /// Coordinated read. `completion` runs on the main queue with `true` once `text` holds the
    /// file's contents; on failure `text` is left untouched (a refused load must leave nothing
    /// savable behind).
    func open(_ completion: @escaping (Bool) -> Void) {
        startPresenting()
        let url = fileURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var loaded: String?
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: self).coordinate(
                readingItemAt: url, options: [], error: &coordinationError
            ) { readURL in
                loaded = try? Self.read(readURL)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard coordinationError == nil, let loaded else {
                    completion(false)
                    return
                }
                self.text = loaded
                completion(true)
            }
        }
    }

    private static func read(_ url: URL) throws -> String {
        if url.isDirectoryOnDisk {
            throw LoadError.notAFile
        }
        return try decode(Data(contentsOf: url))
    }

    // MARK: - Writing

    /// Coordinated, atomic overwrite of `fileURL` with `text` (captured on the calling thread).
    /// `completion` runs on the main queue.
    func save(_ completion: @escaping (Bool) -> Void) {
        startPresenting()
        let url = fileURL
        let data = Data(text.utf8)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var wrote = false
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: self).coordinate(
                writingItemAt: url, options: .forReplacing, error: &coordinationError
            ) { writeURL in
                do {
                    try data.write(to: writeURL, options: .atomic)
                    wrote = true
                } catch {
                    wrote = false
                }
            }
            DispatchQueue.main.async {
                completion(coordinationError == nil && wrote)
            }
        }
    }

    /// Stop presenting the file. The text stays readable afterwards.
    func close() {
        guard isPresenting else { return }
        isPresenting = false
        NSFileCoordinator.removeFilePresenter(self)
    }

    // MARK: - NSFilePresenter

    func presentedItemDidGain(_ version: NSFileVersion) {
        let center = NotificationCenter.default
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            center.post(name: Self.stateChangedNotification, object: self)
        }
    }
}
