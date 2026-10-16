import Foundation

/// The sidebar's file move (rename, drag into folder), off the main thread.
///
/// A coordinated write waits for every presenter of both URLs to relinquish,
/// including CloudDocs and the app's own open `UIDocument`. On the main
/// thread that blocks, and deadlocks when a relinquish needs the main queue.
/// Lives in ChalkKit so `swift test` can assert the threading contract.
public enum CoordinatedFileMove {
    /// The move itself; returns the failure or nil. Substituted in tests.
    public typealias Accessor = (URL, URL) -> Error?

    /// One serial queue for every sidebar move, so two moves in flight cannot
    /// reorder (a rename immediately followed by its own undo).
    public static let queue = DispatchQueue(
        label: "com.huleux.chalk.file-move", qos: .userInitiated)

    /// Run the move on `queue` and report on `completionQueue` (main by
    /// default: callers follow up with view work).
    public static func perform(
        from source: URL,
        to destination: URL,
        on queue: DispatchQueue = queue,
        completeOn completionQueue: DispatchQueue = .main,
        accessor: @escaping Accessor = coordinatedMove,
        completion: @escaping (Error?) -> Void
    ) {
        queue.async {
            let error = accessor(source, destination)
            completionQueue.async { completion(error) }
        }
    }

    /// The default accessor. A bare `moveItem` in an iCloud Location races the
    /// sync daemon (duplicates, spurious conflicts); coordination prevents it.
    public static func coordinatedMove(from source: URL, to destination: URL) -> Error? {
        var coordError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordError
        ) { sourceURL, destinationURL in
            do {
                try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
                coordinator.item(at: sourceURL, didMoveTo: destinationURL)
            } catch {
                moveError = error
            }
        }
        return coordError ?? moveError
    }
}
