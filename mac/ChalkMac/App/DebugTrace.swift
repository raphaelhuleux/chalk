import Foundation

#if DEBUG
/// Appends timestamped lines to the file `CHALK_DEBUG_TRACE` names, when it
/// is set. For lining a window recording up with what the shell did and when;
/// a no-op otherwise, and absent from Release.
enum DebugTrace {
    private static let path = ProcessInfo.processInfo.environment["CHALK_DEBUG_TRACE"]
    private static let start = Date()

    static func log(_ line: @autoclosure () -> String) {
        guard let path else { return }
        let now = Date()
        let text = String(format: "%8.3f  %.3f  ", now.timeIntervalSince(start), now.timeIntervalSince1970) + line() + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            handle.closeFile()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
#endif
